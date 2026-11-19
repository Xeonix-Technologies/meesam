-- Tests for migration 0033: an administrator removes a document; it is kept, audited and no longer listed.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000033a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000033a9', 'owner_company', '{"en": "Stranger"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000033b0', '00000000-0000-0000-0000-0000000033a0', 'adm@x33.test', 'Adm', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000033b1', '00000000-0000-0000-0000-0000000033a0', 'mgr@x33.test', 'Mgr', 'tm_manager', 'active'),
  ('00000000-0000-0000-0000-0000000033b9', '00000000-0000-0000-0000-0000000033a9', 'str@x33.test', 'Str', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000033f1', '00000000-0000-0000-0000-0000000033a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000033e1', '00000000-0000-0000-0000-0000000033f1', g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, sha256) VALUES
  ('00000000-0000-0000-0000-0000000033d1', '00000000-0000-0000-0000-0000000033e1', 'ORC', 'x33/wrong.pdf', 'wrong.pdf', '\x01'),
  ('00000000-0000-0000-0000-0000000033d2', '00000000-0000-0000-0000-0000000033e1', 'POA', 'x33/poa.pdf', 'poa.pdf', '\x02'),
  ('00000000-0000-0000-0000-0000000033d3', '00000000-0000-0000-0000-0000000033e1', 'IMG', 'x33/img.png', 'img.png', '\x03');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-0000000033d3' WHERE id = '00000000-0000-0000-0000-0000000033e1';
DO $$ BEGIN ASSERT (SELECT poa_state FROM core.record WHERE id = '00000000-0000-0000-0000-0000000033e1') = 'present', 'fixture: POA present'; END $$;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000033a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000033b1', true);
DO $$
DECLARE bad boolean := false;
BEGIN
  BEGIN PERFORM core.fn_document_remove('00000000-0000-0000-0000-0000000033d1'); EXCEPTION WHEN insufficient_privilege THEN bad := true; END;
  ASSERT bad, 'a user who is not an administrator cannot remove a document';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000033a9', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000033b9', true);
DO $$
DECLARE bad boolean := false;
BEGIN
  BEGIN PERFORM core.fn_document_remove('00000000-0000-0000-0000-0000000033d1'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'another account cannot remove it';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000033a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000033b0', true);
DO $$
DECLARE bad boolean := false;
BEGIN
  BEGIN PERFORM core.fn_document_remove('00000000-0000-0000-0000-0000000033d3'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'the mark image is not removed here';
  PERFORM core.fn_document_remove('00000000-0000-0000-0000-0000000033d1');
  PERFORM core.fn_document_remove('00000000-0000-0000-0000-0000000033d2');
  ASSERT (SELECT count(*) FROM core.document WHERE record_id = '00000000-0000-0000-0000-0000000033e1') = 1, 'removed documents are no longer listed';
  ASSERT (SELECT count(*) FROM core.fn_record_object_keys('00000000-0000-0000-0000-0000000033e1')) = 3, 'their vault names stay taken';
  ASSERT (SELECT poa_state FROM core.record WHERE id = '00000000-0000-0000-0000-0000000033e1') = 'missing', 'a removed power of attorney no longer counts';
  bad := false;
  BEGIN PERFORM core.fn_document_remove('00000000-0000-0000-0000-0000000033d1'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'a document is removed once';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.document WHERE record_id = '00000000-0000-0000-0000-0000000033e1' AND removed_at IS NOT NULL AND removed_by_user_id = '00000000-0000-0000-0000-0000000033b0') = 2, 'the rows are kept, with who removed them';
END $$;
SELECT 'ALL 0033 TESTS PASSED' AS result;
ROLLBACK;
