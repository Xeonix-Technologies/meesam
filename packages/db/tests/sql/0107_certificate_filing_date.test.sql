-- Tests for migration 0107: the certificate's filing date is read and matched too.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000107a00', 'agency_office', '{"en": "Agency 107"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000107a01', '00000000-0000-0000-0000-000000107a00', 'a@x107.test', 'A', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-000000107f01', '00000000-0000-0000-0000-000000107a00', '{"en": "Filing"}', 'word');
-- the record as typed: filing 17 Apr 2020, expiry 12 Aug 2036; the certificate prints filing 12 Aug 2026
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, entry_mode, paid_state, mark_text, filing_date, expiry_date)
  SELECT '00000000-0000-0000-0000-000000107e01', '00000000-0000-0000-0000-000000107f01', g.id, 'X107-1', 'R107-1', 'bulk_import', 'free_loaded', '{"en": "Filing"}', DATE '2020-04-17', DATE '2036-08-12'
    FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000107d00', '00000000-0000-0000-0000-000000107e01', 'IMG', 'AE/x107_img.png', 'm.png', 'image/png', 10, decode('00', 'hex'), '00000000-0000-0000-0000-000000107a00'),
  ('00000000-0000-0000-0000-000000107d01', '00000000-0000-0000-0000-000000107e01', 'ORC', 'AE/x107_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('01', 'hex'), '00000000-0000-0000-0000-000000107a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000107d00' WHERE id = '00000000-0000-0000-0000-000000107e01';

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000107a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000107a01', true);
DO $$ DECLARE n record; BEGIN
  ASSERT core.fn_certificate_reading_set('00000000-0000-0000-0000-000000107d01', DATE '2036-08-12', DATE '2026-08-12', 'X107-1', NULL, 0.98, 'x', 'test-model', 1, 1) = 'read', 'read with both dates';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000107e01');
  ASSERT n.certificate_state = 'mismatch' AND n.expiry_agrees AND NOT n.filing_agrees AND NOT n.ready, 'the expiry agrees, the filing date does not: held';
  ASSERT n.certificate_filing = DATE '2026-08-12' AND n.record_filing = DATE '2020-04-17', 'and it says which dates';
  ASSERT core.fn_activation_request() = 0, 'not in the basket';
  -- the account corrects the filing date
  UPDATE core.record SET filing_date = DATE '2026-08-12' WHERE id = '00000000-0000-0000-0000-000000107e01';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000107e01');
  ASSERT n.certificate_state = 'match' AND n.filing_agrees AND n.ready, 'both dates agree: ready';
  -- a certificate on which no filing date could be made out is matched on its expiry date alone
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000107d01', DATE '2036-08-12', NULL, 'X107-1', NULL, 0.98, 'x', 'test-model');
  UPDATE core.record SET filing_date = DATE '2020-04-17' WHERE id = '00000000-0000-0000-0000-000000107e01';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000107e01');
  ASSERT n.certificate_state = 'match' AND n.certificate_filing IS NULL, 'no filing date read: the expiry date decides';
  -- a record with no filing date typed does not agree with a certificate that prints one
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000107d01', DATE '2036-08-12', DATE '2026-08-12', 'X107-1', NULL, 0.98, 'x', 'test-model');
  UPDATE core.record SET filing_date = NULL WHERE id = '00000000-0000-0000-0000-000000107e01';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000107e01');
  ASSERT n.certificate_state = 'mismatch' AND NOT n.filing_agrees, 'an empty filing date on the record is a mismatch';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0107 TESTS PASSED
