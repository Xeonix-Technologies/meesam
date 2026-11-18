-- Tests for migration 0016: a registered mark shows renewal clocks, not filing-stage deadlines.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000016a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000016f1', '00000000-0000-0000-0000-0000000016a0', '{"en": "m"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000016e1', '00000000-0000-0000-0000-0000000016f1', g.id, 'T1', current_date - 60, 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id) VALUES
  ('00000000-0000-0000-0000-0000000016e1', 'filed', current_date - 60, 'manual', '{}', '00000000-0000-0000-0000-0000000016a0');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000016e1' AND timer_type = 'priority_document' AND state = 'open' AND due_date > current_date) = 1,
    'a pending application keeps its priority-document date';
END $$;
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id) VALUES
  ('00000000-0000-0000-0000-0000000016e1', 'registered', current_date - 5, 'manual', '{}', '00000000-0000-0000-0000-0000000016a0');
DO $$ BEGIN
  ASSERT (SELECT state FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000016e1' AND timer_type = 'priority_document') = 'cancelled',
    'registration closes the filing-stage deadline';
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000016e1' AND state = 'open') >= 1, 'the renewal clocks stay open';
  ASSERT NOT EXISTS (SELECT 1 FROM core.v_next_dates WHERE record_id = '00000000-0000-0000-0000-0000000016e1' AND timer_type = 'priority_document'), 'and it is no longer a next date';
END $$;
-- a filed event arriving after the registered one (dates corrected later) does not reopen it
UPDATE core.record_event SET event_date = current_date - 50 WHERE record_id = '00000000-0000-0000-0000-0000000016e1' AND event_type = 'filed';
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000016e1' AND timer_type = 'priority_document' AND state = 'open'),
    'a later correction of the filing date does not bring it back';
END $$;
SELECT 'ALL 0016 TESTS PASSED' AS result;
ROLLBACK;
