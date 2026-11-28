-- Tests for migration 0112: the certificate's issuing office and classes are matched; its name is a note.
BEGIN;
-- the tick of 0113 is not this test's subject: every reading counts as confirmed here
CREATE FUNCTION pg_temp.t_confirm() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.confirmed_at := now(); RETURN NEW; END $$;
CREATE TRIGGER zz_test_confirm BEFORE INSERT OR UPDATE ON core.certificate_reading FOR EACH ROW EXECUTE FUNCTION pg_temp.t_confirm();
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000112a00', 'agency_office', '{"en": "Agency 112"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000112a01', '00000000-0000-0000-0000-000000112a00', 'adm@x112.test', 'Adm', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000112f01', '00000000-0000-0000-0000-000000112a00', '{"en": "Milpa"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, filing_date, registration_date, expiry_date, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-000000112e01', '00000000-0000-0000-0000-000000112f01', g.id, 'C112', 'C112', '2026-08-12', '2026-11-11', '2036-08-12', 'bulk_import', 'free_loaded', '{"en": "Milpa"}'
    FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record_class (record_id, nice_class_id) SELECT '00000000-0000-0000-0000-000000112e01', id FROM registry.nice_class WHERE number = 29;
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000112d01', '00000000-0000-0000-0000-000000112e01', 'IMG', 'AE/x112_img.png', 'm.png', 'image/png', 10, decode('02', 'hex'), '00000000-0000-0000-0000-000000112a00'),
  ('00000000-0000-0000-0000-000000112d02', '00000000-0000-0000-0000-000000112e01', 'ORC', 'AE/x112_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('03', 'hex'), '00000000-0000-0000-0000-000000112a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000112d01' WHERE id = '00000000-0000-0000-0000-000000112e01';

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000112a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000112a01', true);
DO $$ DECLARE n record; BEGIN
  -- the right number and dates, but issued by another office
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000112d02', '2036-08-12', '2026-08-12', 'C112', NULL, 0.95, 'x', 'm', NULL, NULL, '2026-11-11', 'sa', ARRAY[29]::smallint[], NULL, 'MILPA');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000112e01');
  ASSERT n.certificate_state = 'mismatch' AND n.number_agrees AND n.office_agrees = false AND n.certificate_office = 'SA' AND n.record_office = 'AE' AND NOT n.ready, 'another office''s certificate: ' || n.certificate_state;
  -- the right office, another class
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000112d02', '2036-08-12', '2026-08-12', 'C112', NULL, 0.95, 'x', 'm', NULL, NULL, '2026-11-11', 'AE', ARRAY[30]::smallint[], NULL, 'Milpa');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000112e01');
  ASSERT n.certificate_state = 'mismatch' AND n.office_agrees AND n.classes_agree = false AND n.certificate_classes = ARRAY[30]::smallint[] AND n.record_classes = ARRAY[29]::smallint[] AND NOT n.ready, 'another class''s certificate';
  -- office and class agree; the name is spelled differently: a note, not a bar
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000112d02', '2036-08-12', '2026-08-12', 'C112', NULL, 0.95, 'x', 'm', NULL, NULL, '2026-11-11', 'AE', ARRAY[29, 29, 99]::smallint[], NULL, 'Milpa Foods');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000112e01');
  ASSERT n.certificate_state = 'match' AND n.classes_agree AND n.name_agrees = false AND n.certificate_name = 'Milpa Foods' AND n.ready, 'a different name does not stop activation: ' || n.certificate_state;
  -- the same name in another letter case and spacing agrees
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000112d02', '2036-08-12', '2026-08-12', 'C112', NULL, 0.95, 'x', 'm', NULL, NULL, '2026-11-11', 'AE', ARRAY[29]::smallint[], NULL, ' MIL-PA ');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000112e01');
  ASSERT n.name_agrees AND n.ready AND n.number_taken = false, 'the same name, written differently';
  -- an office, classes and name the reader could not make out are not held against the certificate
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000112d02', '2036-08-12', '2026-08-12', 'C112', NULL, 0.95, 'x', 'm');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000112e01');
  ASSERT n.certificate_state = 'match' AND n.office_agrees AND n.classes_agree AND n.name_agrees IS NULL AND n.ready, 'nothing read, nothing held against it';
  ASSERT core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000112e01']::uuid[]) = 1, 'and it goes to the basket';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0112 TESTS PASSED
