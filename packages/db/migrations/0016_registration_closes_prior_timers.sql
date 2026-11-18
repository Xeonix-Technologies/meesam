-- 0016 — A registered mark carries no pre-registration deadlines.
-- Founder report 18 Nov 2026: a mark added as already registered showed "Priority document due" as its next
-- date. The filed event opens the registry profile's filing-stage timers (priority document, and later
-- opposition, counter-statement, registration fee, appeal); 0005 closed them only when their date had passed.
-- Once the registry has registered the mark those steps are behind it whatever their dates, so they are closed
-- (met if the date has passed, otherwise no longer applying), leaving the renewal clocks as the next dates. The periods themselves
-- still come from the registry profile (rule 4); nothing here sets a date.
BEGIN;

CREATE FUNCTION core.fn_close_prior_stage_timers(p_record_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = p_record_id AND e.event_type IN ('registered', 'renewed')
                AND (e.source::text <> 'suggested' OR e.confirmed_at IS NOT NULL)) THEN
    -- a date already passed is recorded as met (as fn_close_historical_timers does); one still ahead no longer applies
    UPDATE core.timer SET state = CASE WHEN due_date IS NOT NULL AND due_date < current_date THEN 'met'::core.timer_state ELSE 'cancelled'::core.timer_state END,
                          met_at = CASE WHEN due_date IS NOT NULL AND due_date < current_date THEN now() ELSE met_at END
     WHERE record_id = p_record_id AND state = 'open' AND family = 'statutory'
       AND timer_type IN ('oppose', 'counterstatement', 'pay_registration', 'appeal', 'priority_document');
    GET DIAGNOSTICS n = ROW_COUNT;
  END IF;
  RETURN n;
END $$;

CREATE FUNCTION core.trg_close_prior_stage_timers() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM core.fn_close_prior_stage_timers(NEW.record_id);
  RETURN NULL;
END $$;

-- named to run after record_event_apply (triggers on one event fire in name order), so timers that event
-- has just opened are seen
CREATE TRIGGER record_event_close_prior AFTER INSERT OR UPDATE OF event_date, confirmed_at, event_type ON core.record_event
  FOR EACH ROW EXECUTE FUNCTION core.trg_close_prior_stage_timers();

-- records already registered
SELECT core.fn_close_prior_stage_timers(r.id) FROM core.record r
 WHERE EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type IN ('registered', 'renewed'));

GRANT EXECUTE ON FUNCTION core.fn_close_prior_stage_timers(uuid) TO meesam_app, meesam_worker, meesam_admin;

COMMIT;
