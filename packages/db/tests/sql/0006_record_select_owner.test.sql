-- Tests for migration 0006: an owner can INSERT ... RETURNING on core.record under RLS (the intake commit path).
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-00000000006a', 'owner_individual', '{"en": "F"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000006a', 'f@x.test', 'F', 'company_admin', 'active');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000006a', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000006a1', true);
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000006f1', '00000000-0000-0000-0000-00000000006a', '{"ar": "واحات", "en": "wahaat"}', 'word');
CREATE TEMP TABLE t6 (id uuid);
WITH ins AS (
  INSERT INTO core.record (mark_family_id, registry_id, application_no, registration_no, filing_date, mark_text, entry_mode, paid_state, warnings)
  SELECT '00000000-0000-0000-0000-0000000006f1', id, '407950', '407950', DATE '2023-10-11', '{"en": "wahaat"}', 'existing', 'free_loaded', '[]' FROM registry.registry WHERE code = 'AE'
  RETURNING id)
INSERT INTO t6 SELECT id FROM ins;
DO $$ BEGIN ASSERT (SELECT count(*) FROM t6) = 1, 'insert ... returning works for the owner'; END $$;
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  SELECT id, 'filed', DATE '2023-10-11', 'manual', '{"via": "intake"}', '00000000-0000-0000-0000-00000000006a' FROM t6;
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  SELECT id, 'registered', DATE '2023-11-16', 'manual', '{"via": "intake"}', '00000000-0000-0000-0000-00000000006a' FROM t6;
INSERT INTO core.document (record_id, doc_type, object_key, file_name, sha256, uploaded_by_user_id, uploaded_by_account_id)
  SELECT id, 'ORC', 'AE/407950_001_161123_ORC.pdf', 'cert.pdf', decode('ab', 'hex'), '00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000006a' FROM t6;
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.record WHERE application_no = '407950') = 1, 'owner sees the record'; END $$;
-- another account sees nothing
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000005b', true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.record WHERE application_no = '407950') = 0, 'strangers see nothing'; END $$;
RESET ROLE;
SELECT 'ALL 0006 TESTS PASSED' AS result;
ROLLBACK;
