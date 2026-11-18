-- 0021 — Clocks closed by loading a mark's history are "historical", not "met" (Founder ruling 18 Nov 2026,
-- point 19). "Met" now means the step was done while the record was in Meesam; "historical" means the date
-- had already passed, or the stage was already behind the mark, when the record was loaded or corrected.
BEGIN;

CREATE OR REPLACE FUNCTION core.fn_close_historical_timers(p_record_id uuid, p_as_of date DEFAULT CURRENT_DATE) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE core.timer SET state = 'historical', met_at = now()
   WHERE record_id = p_record_id AND state = 'open' AND due_date IS NOT NULL AND due_date < p_as_of
     AND family = 'statutory' AND timer_type IN ('oppose', 'counterstatement', 'pay_registration', 'appeal', 'priority_document');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION core.fn_close_prior_stage_timers(p_record_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = p_record_id AND e.event_type IN ('registered', 'renewed')
                AND (e.source::text <> 'suggested' OR e.confirmed_at IS NOT NULL)) THEN
    -- a date already passed is history; one still ahead no longer applies
    UPDATE core.timer SET state = CASE WHEN due_date IS NOT NULL AND due_date < current_date THEN 'historical'::core.timer_state ELSE 'cancelled'::core.timer_state END,
                          met_at = CASE WHEN due_date IS NOT NULL AND due_date < current_date THEN now() ELSE met_at END
     WHERE record_id = p_record_id AND state = 'open' AND family = 'statutory'
       AND timer_type IN ('oppose', 'counterstatement', 'pay_registration', 'appeal', 'priority_document');
    GET DIAGNOSTICS n = ROW_COUNT;
  END IF;
  RETURN n;
END $$;

-- Clocks already closed as "met" on marks loaded with their history: the ones closed at loading, or behind a
-- registration, become historical. Anything a user closed later stays met.
UPDATE core.timer t SET state = 'historical'
  FROM core.record r
 WHERE r.id = t.record_id AND r.entry_mode = 'existing' AND t.state = 'met' AND t.family = 'statutory'
   AND t.timer_type IN ('oppose', 'counterstatement', 'pay_registration', 'appeal', 'priority_document')
   AND (t.met_at <= r.created_at + interval '5 minutes' OR r.registration_date IS NOT NULL);

COMMIT;
