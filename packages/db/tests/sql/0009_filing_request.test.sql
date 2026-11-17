-- Tests for migration 0009: a filing request is a record at stage pre_filing; recording "filed" moves it to stage 2.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-00000000090a', 'owner_company', '{"en": "Q"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000090a1', '00000000-0000-0000-0000-00000000090a', 'q@x.test', 'Q', 'company_admin', 'active');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000090a', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000090a1', true);
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000090f1', '00000000-0000-0000-0000-00000000090a', '{"en": "Pastina"}', 'word');
CREATE TEMP TABLE t9 (id uuid);
WITH ins AS (
  INSERT INTO core.record (mark_family_id, registry_id, mark_text, entry_mode, paid_state, filing_request)
  SELECT '00000000-0000-0000-0000-0000000090f1', id, '{"en": "Pastina"}', 'new_filing', 'free_new_pending',
         '{"applicant": {"name_en": "Q"}, "route": {"who": "self"}, "priority": null}'::jsonb FROM registry.registry WHERE code = 'AE'
  RETURNING id)
INSERT INTO t9 SELECT id FROM ins;
INSERT INTO core.record_class (record_id, nice_class_id, terms) SELECT t9.id, c.id, '[{"en": "Restaurant services"}]'::jsonb FROM t9, registry.nice_class c WHERE c.number = 43;
INSERT INTO core.document (record_id, doc_type, object_key, file_name, sha256, uploaded_by_user_id, uploaded_by_account_id)
  SELECT id, 'POA', 'AE/REQ12345678_001_171126_POA.pdf', 'poa.pdf', decode('ab', 'hex'), '00000000-0000-0000-0000-0000000090a1', '00000000-0000-0000-0000-00000000090a' FROM t9;
DO $$ BEGIN
  ASSERT (SELECT stage FROM core.record r JOIN t9 ON t9.id = r.id) = 'pre_filing', 'a filing request sits at stage 1';
  ASSERT (SELECT filing_request -> 'route' ->> 'who' FROM core.record r JOIN t9 ON t9.id = r.id) = 'self', 'request content kept on the record';
END $$;
-- the owner files with the registry and records the number and date
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  SELECT id, 'filed', current_date, 'manual', '{"number": "500001"}', '00000000-0000-0000-0000-00000000090a' FROM t9;
UPDATE core.record r SET application_no = '500001', filing_date = current_date FROM t9 WHERE r.id = t9.id;
DO $$ BEGIN
  ASSERT (SELECT stage FROM core.record r JOIN t9 ON t9.id = r.id) = 'filing_examination', 'filed moves the record to stage 2';
END $$;
RESET ROLE;
SELECT 'ALL 0009 TESTS PASSED' AS result;
ROLLBACK;
