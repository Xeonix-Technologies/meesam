-- Tests for migration 0109: the registration date read from a certificate is kept, and the dates of the certificate that counts are given.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000109a00', 'agency_office', '{"en": "Agency 109"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000109a01', '00000000-0000-0000-0000-000000109a00', 'a@x109.test', 'A', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-000000109f01', '00000000-0000-0000-0000-000000109a00', '{"en": "D"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, entry_mode, paid_state, mark_text, filing_date, expiry_date)
  SELECT '00000000-0000-0000-0000-000000109e01', '00000000-0000-0000-0000-000000109f01', g.id, 'X109-1', 'X109-1', 'bulk_import', 'free_loaded', '{"en": "D"}', DATE '2024-05-04', DATE '2034-05-04'
    FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000109d01', '00000000-0000-0000-0000-000000109e01', 'ORC', 'AE/x109_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('01', 'hex'), '00000000-0000-0000-0000-000000109a00');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000109a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000109a01', true);
DO $$ DECLARE c record; n record; BEGIN
  ASSERT (SELECT expiry_date IS NULL FROM core.fn_certificate_dates('00000000-0000-0000-0000-000000109e01')), 'nothing read yet: no dates';
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000109d01', DATE '2036-08-12', DATE '2026-08-12', '488477', NULL, 0.98, 'x', 'test-model', 1, 1, DATE '2026-11-11');
  SELECT * INTO c FROM core.fn_certificate_dates('00000000-0000-0000-0000-000000109e01');
  ASSERT c.filing_date = DATE '2026-08-12' AND c.registration_date = DATE '2026-11-11' AND c.expiry_date = DATE '2036-08-12', 'the three dates of the certificate';
  -- the number is another's: held, and nothing about the record has changed
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000109e01');
  ASSERT n.certificate_state = 'mismatch' AND NOT n.number_agrees, 'the number does not agree';
  -- the account corrects the number; the dates can then be taken from the certificate, as the application does
  PERFORM core.fn_correct_certificate('00000000-0000-0000-0000-000000109e01', '488477', NULL, NULL, NULL, NULL);
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000109e01');
  ASSERT n.number_agrees AND n.certificate_state = 'mismatch', 'the certificate''s one number is now one of the record''s; the dates still differ';
  PERFORM core.fn_correct_certificate('00000000-0000-0000-0000-000000109e01', NULL, c.filing_date, NULL, c.registration_date, c.expiry_date);
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000109e01');
  ASSERT n.certificate_state = 'match', 'with the certificate''s dates the record matches';
  ASSERT (SELECT registration_date FROM core.record WHERE id = '00000000-0000-0000-0000-000000109e01') = DATE '2026-11-11', 'the registration date is the certificate''s';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0109 TESTS PASSED
