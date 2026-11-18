-- 0020 — Founder rulings of 18 Nov 2026 (points 1, 7, 18, 19 of the ruling list).
--   1.  Taking a record back after an owner pass is possible for 30 days from the day the pass was used.
--   7.  The priority-document deadline opens only when the record says priority is claimed. The condition
--       lives in the registry profile (a timer may carry "requires"), not in code.
--   18. The mark's image gets its own document type, IMG — a 15th code beside the 14 of item 14.16.
--   19. Clocks closed because a mark was loaded with its history get a state of their own, "historical"
--       (the value is added here and used from migration 0021: a new enum value cannot be used in the
--       transaction that adds it).
BEGIN;

ALTER TYPE core.timer_state ADD VALUE IF NOT EXISTS 'historical';

-- 18. the mark image
INSERT INTO core.document_type (code, name) VALUES ('IMG', '{"en": "Mark image", "ar": "صورة العلامة"}') ON CONFLICT (code) DO NOTHING;
UPDATE core.document d SET doc_type = 'IMG' FROM core.record r WHERE r.mark_image_doc_id = d.id AND d.doc_type = 'OTH';

-- 7. priority claimed
ALTER TABLE core.record ADD COLUMN IF NOT EXISTS priority_claimed boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN core.record.priority_claimed IS 'The application claims priority from an earlier filing; opens the profile timers that require it';
UPDATE core.record SET priority_claimed = true WHERE jsonb_typeof(filing_request -> 'priority') = 'object';
UPDATE registry.registry_profile SET rules = jsonb_set(rules, '{timers,priority_document,requires}', '"priority_claimed"')
 WHERE rules -> 'timers' ? 'priority_document';
-- clocks opened under the old rule on records with no priority claim no longer apply
UPDATE core.timer t SET state = 'cancelled'
  FROM core.record r WHERE r.id = t.record_id AND NOT r.priority_claimed AND t.state = 'open' AND t.timer_type = 'priority_document';

-- As 0008, with one line added: a timer whose profile entry carries "requires" opens only when the record meets it.
CREATE OR REPLACE FUNCTION core.fn_timers_for_event(p_event_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
AS $fn$
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
    -- 0020: a conditional timer (profile "requires") opens only when the record meets the condition
    CONTINUE WHEN spec ->> 'requires' = 'priority_claimed' AND NOT COALESCE(r.priority_claimed, false);
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
END $fn$
;

-- Sets the priority claim on a record and brings its clocks in line: opens the timers that require the claim
-- (from the event they start at, by the profile's own period) or cancels them. Row-level security decides
-- who may change the record, as for the other corrections.
CREATE FUNCTION core.fn_set_priority_claimed(p_record_id uuid, p_claimed boolean) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r core.record; e core.record_event; prof registry.registry_profile; tz text; k text; spec jsonb; v_due date;
BEGIN
  UPDATE core.record SET priority_claimed = COALESCE(p_claimed, false) WHERE id = p_record_id AND priority_claimed IS DISTINCT FROM COALESCE(p_claimed, false) RETURNING * INTO r;
  IF r.id IS NULL THEN RETURN; END IF;                       -- no such record for this caller, or nothing changed
  FOR e IN SELECT * FROM core.record_event WHERE record_id = r.id AND (source::text <> 'suggested' OR confirmed_at IS NOT NULL) LOOP
    prof := registry.fn_current_profile(r.registry_id, e.event_date);
    CONTINUE WHEN prof.id IS NULL;
    tz := prof.rules -> 'calendar' ->> 'timezone';
    FOR k, spec IN SELECT key, value FROM jsonb_each(prof.rules -> 'timers') LOOP
      CONTINUE WHEN spec ->> 'requires' IS DISTINCT FROM 'priority_claimed' OR spec ->> 'start_event' IS DISTINCT FROM e.event_type::text;
      IF NOT r.priority_claimed THEN
        UPDATE core.timer SET state = 'cancelled' WHERE record_id = r.id AND event_id = e.id AND timer_type = k AND state = 'open';
      ELSIF NOT EXISTS (SELECT 1 FROM core.timer WHERE record_id = r.id AND event_id = e.id AND timer_type = k AND state <> 'cancelled') THEN
        IF NOT COALESCE((spec ->> 'verified')::boolean, prof.verified) THEN
          INSERT INTO core.timer (record_id, event_id, family, timer_type, source, awaiting_user_entry) VALUES (r.id, e.id, 'statutory', k, 'user_entered', true);
        ELSIF spec ? 'days' OR spec ? 'months' THEN
          v_due := CASE WHEN spec ? 'days' THEN e.event_date + (spec ->> 'days')::integer
                        ELSE (e.event_date + make_interval(months => (spec ->> 'months')::integer))::date END;
          INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
          VALUES (r.id, e.id, 'statutory', k, v_due, core.fn_due_at(v_due, tz), 'profile');
        END IF;
      END IF;
    END LOOP;
  END LOOP;
  PERFORM core.fn_close_historical_timers(r.id);
  PERFORM core.fn_close_prior_stage_timers(r.id);
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_set_priority_claimed(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_set_priority_claimed(uuid, boolean) TO meesam_app, meesam_worker, meesam_admin;

-- 1. take-back within 30 days of redemption (as 0019 otherwise)
CREATE OR REPLACE FUNCTION core.fn_pass_can_take_back(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.owner_pass p JOIN core.record r ON r.id = p.record_id JOIN core.mark_family f ON f.id = r.mark_family_id
     WHERE p.record_id = p_record_id AND p.issued_by_account_id = platform.current_account_id()
       AND p.redeemed_at IS NOT NULL AND p.taken_back_at IS NULL AND f.owner_account_id = p.redeemed_by_account_id
       AND p.redeemed_at > now() - interval '30 days'
       AND platform.current_account_id() IN (SELECT core.fn_holding_agencies(p_record_id)))
$$;

COMMIT;
