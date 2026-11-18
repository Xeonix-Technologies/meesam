-- Tests for migrations 0020 and 0021: priority claim opens the priority clock; historical state; IMG type; take-back window.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000020a0', 'owner_company', '{"en": "O"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000020f1', '00000000-0000-0000-0000-0000000020a0', '{"en": "a"}', 'word'),
  ('00000000-0000-0000-0000-0000000020f2', '00000000-0000-0000-0000-0000000020a0', '{"en": "b"}', 'word');
-- a fresh filing, no priority claimed
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000020e1', '00000000-0000-0000-0000-0000000020f1', g.id, 'N1', current_date - 10, 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record_event (record_id, event_type, event_date, source) VALUES ('00000000-0000-0000-0000-0000000020e1', 'filed', current_date - 10, 'manual');
DO $$
DECLARE d date;
BEGIN
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000020e1' AND timer_type = 'priority_document' AND state = 'open') = 0, 'no priority clock without a claim';
  PERFORM core.fn_set_priority_claimed('00000000-0000-0000-0000-0000000020e1', true);
  SELECT due_date INTO d FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000020e1' AND timer_type = 'priority_document' AND state = 'open';
  ASSERT d = ((current_date - 10) + interval '6 months')::date, 'the claim opens the clock by the profile period';
  PERFORM core.fn_set_priority_claimed('00000000-0000-0000-0000-0000000020e1', true);
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000020e1' AND timer_type = 'priority_document' AND state = 'open') = 1, 'not twice';
  PERFORM core.fn_set_priority_claimed('00000000-0000-0000-0000-0000000020e1', false);
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000020e1' AND timer_type = 'priority_document' AND state = 'open') = 0, 'withdrawing the claim cancels it';
END $$;
-- an old filing with a claim: the passed date is historical, not met
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state, priority_claimed)
  SELECT '00000000-0000-0000-0000-0000000020e2', '00000000-0000-0000-0000-0000000020f2', g.id, 'N2', DATE '2020-01-01', 'existing', 'free_loaded', true FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record_event (record_id, event_type, event_date, source) VALUES ('00000000-0000-0000-0000-0000000020e2', 'filed', DATE '2020-01-01', 'manual');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000020e2' AND timer_type = 'priority_document') = 1, 'a claimed priority opens the clock at filing';
  PERFORM core.fn_close_historical_timers('00000000-0000-0000-0000-0000000020e2');
  ASSERT (SELECT state::text FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000020e2' AND timer_type = 'priority_document') = 'historical', 'a date long passed is historical';
  ASSERT EXISTS (SELECT 1 FROM core.document_type WHERE code = 'IMG'), 'the mark image has its own document type';
  ASSERT (SELECT rules -> 'timers' -> 'priority_document' ->> 'requires' FROM registry.registry_profile WHERE rules -> 'timers' ? 'priority_document' LIMIT 1) = 'priority_claimed', 'the condition is in the profile';
END $$;
SELECT 'ALL 0020 TESTS PASSED' AS result;
ROLLBACK;
