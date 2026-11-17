-- 0008: correcting certificate information re-flows the clocks (item 44) and the certificate's own
-- expiry date drives the renewal, expiry and grace clocks (item 37).
--  * fn_timers_for_event: on 'registered', an expiry passed in the transaction-local setting
--    meesam.keep_expiry replaces the term-computed one.
--  * fn_correct_certificate: one call that updates the record's certificate fields, moves the dates of
--    the filed and registered events to match, and regenerates their clocks. Runs as the caller (RLS applies).
BEGIN;

CREATE OR REPLACE FUNCTION core.fn_timers_for_event(p_event_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  e core.record_event; r core.record; prof registry.registry_profile; tz text;
  k text; spec jsonb; v_due date; v_verified boolean; n integer := 0; base date; months integer;
  rem jsonb; rem_base date; rem_months jsonb;
BEGIN
  SELECT * INTO e FROM core.record_event WHERE id = p_event_id;
  IF e.source = 'suggested' AND e.confirmed_at IS NULL THEN RETURN 0; END IF;
  SELECT * INTO r FROM core.record WHERE id = e.record_id;
  prof := registry.fn_current_profile(r.registry_id, e.event_date);
  IF prof.id IS NULL THEN RETURN 0; END IF;
  tz := prof.rules -> 'calendar' ->> 'timezone';

  -- Registration sets expiry from the term rule (filing_date + N years, or registration_date for US/CN).
  IF e.event_type = 'registered' AND prof.rules ? 'term' THEN
    base := CASE prof.rules -> 'term' ->> 'from' WHEN 'registration_date' THEN e.event_date ELSE COALESCE(r.filing_date, e.event_date) END;
    v_due := (base + make_interval(years => COALESCE((prof.rules -> 'term' ->> 'years')::integer, 10)))::date;
    -- the certificate's own expiry wins over the computed one (certificate information is editable, item 37):
    -- core.fn_correct_certificate and the intake commit pass it for the length of their transaction
    v_due := COALESCE(NULLIF(current_setting('meesam.keep_expiry', true), '')::date, v_due);
    UPDATE core.record SET registration_date = COALESCE(registration_date, e.event_date), expiry_date = v_due WHERE id = r.id;
    r.expiry_date := v_due;
  END IF;

  FOR k, spec IN SELECT key, value FROM jsonb_each(prof.rules -> 'timers') LOOP
    CONTINUE WHEN spec ->> 'start_event' IS DISTINCT FROM e.event_type::text;
    v_verified := COALESCE((spec ->> 'verified')::boolean, prof.verified);
    IF NOT v_verified THEN
      INSERT INTO core.timer (record_id, event_id, family, timer_type, source, awaiting_user_entry)
      VALUES (r.id, e.id, 'statutory', k, 'user_entered', true);
      n := n + 1; CONTINUE;
    END IF;
    IF spec ? 'days' THEN
      v_due := e.event_date + (spec ->> 'days')::integer;
    ELSIF spec ? 'months' THEN
      v_due := (e.event_date + make_interval(months => (spec ->> 'months')::integer))::date;
    ELSIF spec ? 'months_before_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := (r.expiry_date - make_interval(months => (spec ->> 'months_before_expiry')::integer))::date;
    ELSIF spec ? 'months_after_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := (r.expiry_date + make_interval(months => (spec ->> 'months_after_expiry')::integer))::date;
    ELSIF spec ? 'at_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := r.expiry_date;
    ELSE
      CONTINUE;
    END IF;
    INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
    VALUES (r.id, e.id, 'statutory', k, v_due, core.fn_due_at(v_due, tz), 'profile');
    n := n + 1;

    rem := prof.rules -> 'reminders' -> k;
    IF rem IS NOT NULL THEN
      IF jsonb_typeof(rem) = 'array' THEN
        rem_base := r.expiry_date; rem_months := rem;
      ELSE
        rem_base := CASE rem ->> 'before' WHEN 'due' THEN v_due ELSE r.expiry_date END;
        rem_months := rem -> 'months';
      END IF;
      IF rem_base IS NOT NULL THEN
        FOR months IN SELECT (x)::integer FROM jsonb_array_elements_text(rem_months) x LOOP
          INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
          VALUES (r.id, e.id, 'reminder', format('%s_reminder_%sm', k, months),
                  (rem_base - make_interval(months => months))::date,
                  core.fn_due_at((rem_base - make_interval(months => months))::date, tz), 'profile');
          n := n + 1;
        END LOOP;
      END IF;
    END IF;
  END LOOP;
  RETURN n;
END $$;

CREATE FUNCTION core.fn_correct_certificate(p_record_id uuid, p_application_no text, p_filing_date date,
                                            p_registration_no text, p_registration_date date, p_expiry_date date)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r core.record;
BEGIN
  UPDATE core.record SET application_no = COALESCE(p_application_no, application_no), filing_date = COALESCE(p_filing_date, filing_date),
                         registration_no = COALESCE(p_registration_no, registration_no), registration_date = COALESCE(p_registration_date, registration_date),
                         expiry_date = COALESCE(p_expiry_date, expiry_date)
   WHERE id = p_record_id RETURNING * INTO r;
  IF r.id IS NULL THEN RETURN; END IF;
  PERFORM set_config('meesam.keep_expiry', COALESCE(r.expiry_date::text, ''), true);
  -- move the event dates; the record_event trigger cancels each event's open clocks and regenerates them
  IF r.filing_date IS NOT NULL THEN
    UPDATE core.record_event SET event_date = r.filing_date WHERE record_id = r.id AND event_type = 'filed';
  END IF;
  IF r.registration_date IS NOT NULL THEN
    UPDATE core.record_event SET event_date = r.registration_date WHERE record_id = r.id AND event_type = 'registered';
  END IF;
  PERFORM set_config('meesam.keep_expiry', '', true);
  PERFORM core.fn_close_historical_timers(r.id);
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_correct_certificate(uuid, text, date, text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_correct_certificate(uuid, text, date, text, date, date) TO meesam_app, meesam_worker, meesam_admin;

COMMIT;
