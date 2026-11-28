-- Tests for migration 0106: the certificate is read; activation waits until its expiry date and the record's agree.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000106a00', 'agency_office', '{"en": "Agency 106"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000106b00', 'agency_office', '{"en": "Other 106"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000106a01', '00000000-0000-0000-0000-000000106a00', 'a@x106.test', 'A', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000106b01', '00000000-0000-0000-0000-000000106b00', 'b@x106.test', 'B', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-000000106f01', '00000000-0000-0000-0000-000000106a00', '{"en": "Cert"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, entry_mode, paid_state, mark_text, expiry_date)
  SELECT '00000000-0000-0000-0000-000000106e01', '00000000-0000-0000-0000-000000106f01', g.id, 'X106-1', 'R106-1', 'bulk_import', 'free_loaded', '{"en": "Cert"}', DATE '2028-03-10'
    FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000106d00', '00000000-0000-0000-0000-000000106e01', 'IMG', 'AE/x106_img.png', 'm.png', 'image/png', 10, decode('00', 'hex'), '00000000-0000-0000-0000-000000106a00'),
  ('00000000-0000-0000-0000-000000106d01', '00000000-0000-0000-0000-000000106e01', 'ORC', 'AE/x106_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('01', 'hex'), '00000000-0000-0000-0000-000000106a00'),
  ('00000000-0000-0000-0000-000000106d09', '00000000-0000-0000-0000-000000106e01', 'POA', 'AE/x106_poa.pdf', 'p.pdf', 'application/pdf', 10, decode('09', 'hex'), '00000000-0000-0000-0000-000000106a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000106d00' WHERE id = '00000000-0000-0000-0000-000000106e01';

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000106a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000106a01', true);
DO $$ DECLARE n record; denied boolean := false; BEGIN
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000106e01');
  ASSERT n.certificate_state = 'unread' AND NOT n.ready, format('a certificate not read yet holds activation: %s', n.certificate_state);
  ASSERT core.fn_activation_request() = 0, 'nothing goes in the basket';
  -- the reader could not make out a date: a clearer copy is asked for
  ASSERT core.fn_certificate_reading_set('00000000-0000-0000-0000-000000106d01', NULL, 0.2, NULL, 'test-model', 1500, 80) = 'unclear', 'no date read: unclear';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000106e01');
  ASSERT n.certificate_state = 'unclear' AND NOT n.ready, 'unclear holds activation';
  -- a document that is not a certificate cannot carry a reading
  BEGIN PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000106d09', DATE '2028-03-10', 0.9, 'x', 'm'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a power of attorney is not read as a certificate';
END $$;
RESET ROLE;
-- a clearer copy arrives
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000106d02', '00000000-0000-0000-0000-000000106e01', 'ORC', 'AE/x106_orc2.pdf', 'c2.pdf', 'application/pdf', 10, decode('02', 'hex'), '00000000-0000-0000-0000-000000106a00');
-- another account cannot write a reading on it
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000106b00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000106b01', true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000106d02', DATE '2028-03-10', 0.9, 'x', 'm'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'another account writes no reading';
  ASSERT (SELECT count(*) FROM core.certificate_reading) = 0, 'and reads none';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000106a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000106a01', true);
DO $$ DECLARE n record; denied boolean := false; BEGIN
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000106e01');
  ASSERT n.certificate_state = 'unread', 'the new copy waits to be read';
  -- read: the certificate says 2034, the record says 2028
  ASSERT core.fn_certificate_reading_set('00000000-0000-0000-0000-000000106d02', DATE '2034-03-10', 0.97, 'Expiry date: 10/03/2034', 'test-model', 1600, 90) = 'read', 'read';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000106e01');
  ASSERT n.certificate_state = 'mismatch' AND n.certificate_expiry = DATE '2034-03-10' AND n.record_expiry = DATE '2028-03-10' AND NOT n.ready, 'the dates differ: held';
  ASSERT core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000106e01']::uuid[]) = 0, 'a mismatch does not reach the basket';
  -- the reading never changed the record
  ASSERT (SELECT expiry_date FROM core.record WHERE id = '00000000-0000-0000-0000-000000106e01') = DATE '2028-03-10', 'the record keeps what the account typed';
  -- the app role cannot write the table itself
  BEGIN UPDATE core.certificate_reading SET expiry_date = DATE '2028-03-10'; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no direct write of a reading';
  -- the account corrects the record's date
  UPDATE core.record SET expiry_date = DATE '2034-03-10' WHERE id = '00000000-0000-0000-0000-000000106e01';
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000106e01');
  ASSERT n.certificate_state = 'match' AND n.ready, 'the dates agree: ready';
  ASSERT core.fn_activation_request() = 1, 'and it goes in the basket';
  ASSERT (SELECT years_remaining FROM core.fn_basket()) >= 7, 'priced by the certificate''s years';
END $$;
RESET ROLE;
-- a renewal certificate with a later date supersedes: the record is behind again
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000106d03', '00000000-0000-0000-0000-000000106e01', 'REN', 'AE/x106_ren.pdf', 'r.pdf', 'application/pdf', 10, decode('03', 'hex'), '00000000-0000-0000-0000-000000106a00');
INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, confidence) VALUES ('00000000-0000-0000-0000-000000106d03', '00000000-0000-0000-0000-000000106e01', 'read', DATE '2044-03-10', 0.9);
DO $$ DECLARE n record; BEGIN
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000106e01');
  ASSERT n.certificate_state = 'mismatch' AND n.certificate_expiry = DATE '2044-03-10', 'the latest expiry read counts';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE table_name = 'certificate_reading') >= 3, 'readings are audited';
END $$;
ROLLBACK;
\echo ALL 0106 TESTS PASSED
