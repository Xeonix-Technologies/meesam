-- Tests for migration 0108: the certificate's numbers are read and matched, so one certificate serves one record.
BEGIN;
-- the tick of 0113 is not this test's subject: every reading counts as confirmed here
CREATE FUNCTION pg_temp.t_confirm() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.confirmed_at := now(); RETURN NEW; END $$;
CREATE TRIGGER zz_test_confirm BEFORE INSERT OR UPDATE ON core.certificate_reading FOR EACH ROW EXECUTE FUNCTION pg_temp.t_confirm();
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000108a00', 'agency_office', '{"en": "Agency 108"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000108a01', '00000000-0000-0000-0000-000000108a00', 'a@x108.test', 'A', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000108f01', '00000000-0000-0000-0000-000000108a00', '{"en": "One"}', 'word'),
  ('00000000-0000-0000-0000-000000108f02', '00000000-0000-0000-0000-000000108a00', '{"en": "Two"}', 'word');
-- two records with the same dates; the certificate is that of the first (application 488477)
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, entry_mode, paid_state, mark_text, filing_date, expiry_date)
  SELECT v.id::uuid, v.fam::uuid, g.id, v.app, v.reg, 'bulk_import', 'free_loaded', '{"en": "M"}', DATE '2026-08-12', DATE '2036-08-12'
    FROM registry.registry g, (VALUES ('00000000-0000-0000-0000-000000108e01', '00000000-0000-0000-0000-000000108f01', '488477', NULL),
                                      ('00000000-0000-0000-0000-000000108e02', '00000000-0000-0000-0000-000000108f02', 'X108-2', 'R108-2')) v(id, fam, app, reg)
   WHERE g.code = 'AE';
UPDATE core.record SET registration_date = DATE '2026-11-11' WHERE id = '00000000-0000-0000-0000-000000108e01';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000108d10', '00000000-0000-0000-0000-000000108e01', 'IMG', 'AE/x108_1.png', 'm.png', 'image/png', 10, decode('10', 'hex'), '00000000-0000-0000-0000-000000108a00'),
  ('00000000-0000-0000-0000-000000108d11', '00000000-0000-0000-0000-000000108e01', 'ORC', 'AE/x108_1.pdf', 'c.pdf', 'application/pdf', 10, decode('11', 'hex'), '00000000-0000-0000-0000-000000108a00'),
  ('00000000-0000-0000-0000-000000108d20', '00000000-0000-0000-0000-000000108e02', 'IMG', 'AE/x108_2.png', 'm.png', 'image/png', 10, decode('20', 'hex'), '00000000-0000-0000-0000-000000108a00'),
  ('00000000-0000-0000-0000-000000108d21', '00000000-0000-0000-0000-000000108e02', 'ORC', 'AE/x108_2.pdf', 'c.pdf', 'application/pdf', 10, decode('11', 'hex'), '00000000-0000-0000-0000-000000108a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000108d10' WHERE id = '00000000-0000-0000-0000-000000108e01';
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000108d20' WHERE id = '00000000-0000-0000-0000-000000108e02';
DO $$ BEGIN
  ASSERT core.fn_number_key(' 488-477 ') = '488477' AND core.fn_number_key('r108/2') = 'R1082' AND core.fn_number_key(' - ') IS NULL, 'numbers are compared without spaces, punctuation or case';
END $$;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000108a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000108a01', true);
DO $$ DECLARE n record; BEGIN
  -- the same certificate read on both records: both dates agree on both
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000108d11', DATE '2036-08-12', DATE '2026-08-12', '488477', NULL, 0.98, 'x', 'test-model');
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000108d21', DATE '2036-08-12', DATE '2026-08-12', '488477', NULL, 0.98, 'x', 'test-model');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000108e01');
  ASSERT n.certificate_state = 'match' AND n.number_agrees AND n.ready, 'its own record: the number agrees, ready';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000108e02');
  ASSERT n.certificate_state = 'mismatch' AND n.expiry_agrees AND n.filing_agrees AND NOT n.number_agrees AND NOT n.ready, 'another record: same dates, another number: held';
  ASSERT n.certificate_number = '488477', 'and it says which number the certificate gives';
  ASSERT core.fn_activation_request() = 1, 'only the certificate''s own record reaches the basket';
  -- the second record cannot take the number: a registry''s number belongs to one record
  BEGIN
    UPDATE core.record SET application_no = '488477' WHERE id = '00000000-0000-0000-0000-000000108e02';
    ASSERT false, 'the same number on a second record must be refused';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  -- a number typed as the registration number, with a space and a dash, is the same number
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000108d21', DATE '2036-08-12', DATE '2026-08-12', 'x108 2', 'R-108-2', 0.98, 'x', 'test-model');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000108e02');
  ASSERT n.certificate_state = 'match' AND n.number_agrees, 'both numbers of its own certificate agree, however spaced';
  -- one right number and one wrong number is not a match
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000108d21', DATE '2036-08-12', DATE '2026-08-12', 'X108-2', '999999', 0.98, 'x', 'test-model');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000108e02');
  ASSERT n.certificate_state = 'mismatch' AND NOT n.number_agrees, 'every number the certificate gives must be the record''s';
  -- a certificate on which no number could be made out cannot be tied to a record
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000108d21', DATE '2036-08-12', DATE '2026-08-12', NULL, ' ', 0.98, 'x', 'test-model');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000108e02');
  ASSERT n.certificate_state = 'unclear' AND NOT n.ready, 'no number read: a clearer copy is asked for';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0108 TESTS PASSED
