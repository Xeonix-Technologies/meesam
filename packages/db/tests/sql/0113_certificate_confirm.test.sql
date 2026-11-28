-- Tests for migration 0113: the record is filled from its certificate, confirmed with a tick; a correction is checked.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000113a00', 'agency_office', '{"en": "Agency 113"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000113a01', '00000000-0000-0000-0000-000000113a00', 'adm@x113.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000113a02', '00000000-0000-0000-0000-000000113a00', 'view@x113.test', 'View', 'viewer', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000113f01', '00000000-0000-0000-0000-000000113a00', '{"en": "Typed wrong"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, filing_date, registration_date, expiry_date, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-000000113e01', '00000000-0000-0000-0000-000000113f01', g.id, 'C113', 'C113', '2026-08-12', '2026-11-11', '2036-08-12', 'bulk_import', 'free_loaded', '{"en": "Typed wrong"}'
    FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record_class (record_id, nice_class_id) SELECT '00000000-0000-0000-0000-000000113e01', id FROM registry.nice_class WHERE number = 5;
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000113d01', '00000000-0000-0000-0000-000000113e01', 'IMG', 'AE/x113_img.png', 'm.png', 'image/png', 10, decode('02', 'hex'), '00000000-0000-0000-0000-000000113a00'),
  ('00000000-0000-0000-0000-000000113d02', '00000000-0000-0000-0000-000000113e01', 'ORC', 'AE/x113_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('03', 'hex'), '00000000-0000-0000-0000-000000113a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000113d01' WHERE id = '00000000-0000-0000-0000-000000113e01';
CREATE TEMP TABLE t113 (k text PRIMARY KEY, id uuid); GRANT ALL ON t113 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000113a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000113a01', true);
DO $$ DECLARE n record; code text := ''; v uuid; BEGIN
  -- the certificate is this record's (number and office): the wording and the classes are taken from it
  PERFORM core.fn_certificate_reading_set('00000000-0000-0000-0000-000000113d02', '2036-08-12', '2026-08-12', 'C113', NULL, 0.95, 'x', 'm', 100, 20, '2026-11-11', 'AE', ARRAY[29, 30]::smallint[], 'ميلبا', 'Milpa');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000113e01');
  ASSERT n.certificate_state = 'mismatch' AND n.classes_agree = false, 'before the fill the classes differ';
  ASSERT core.fn_certificate_apply('00000000-0000-0000-0000-000000113e01'), 'the fill changes the record';
  ASSERT (SELECT mark_text FROM core.record WHERE id = '00000000-0000-0000-0000-000000113e01') = '{"en": "Milpa", "ar": "ميلبا"}'::jsonb, 'the wording is the certificate''s';
  ASSERT (SELECT array_agg(c.number ORDER BY c.number) FROM core.record_class rc JOIN registry.nice_class c ON c.id = rc.nice_class_id WHERE rc.record_id = '00000000-0000-0000-0000-000000113e01') = ARRAY[29, 30]::smallint[], 'the classes are the certificate''s';
  ASSERT NOT core.fn_certificate_apply('00000000-0000-0000-0000-000000113e01'), 'a second fill changes nothing';
  -- it agrees now, but is not ready before the tick
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000113e01');
  ASSERT n.certificate_state = 'match' AND NOT n.certificate_confirmed AND NOT n.ready, 'agreeing but not confirmed is not ready';
  ASSERT core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000113e01']::uuid[]) = 0, 'and does not go to the basket';
  PERFORM core.fn_certificate_confirm('00000000-0000-0000-0000-000000113e01');
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000113e01');
  ASSERT n.certificate_confirmed AND n.ready, 'confirmed: ready';
  -- a correction takes the tick away and holds activation while it is open
  BEGIN PERFORM core.fn_certificate_correction_open('00000000-0000-0000-0000-000000113e01', 'application_no', '999'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '22023', 'the number is never corrected this way: ' || code;
  code := '';
  BEGIN PERFORM core.fn_certificate_correction_open('00000000-0000-0000-0000-000000113e01', 'classes', '29, 77'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '22023', 'a class is 1 to 45: ' || code;
  v := core.fn_certificate_correction_open('00000000-0000-0000-0000-000000113e01', 'mark_text_en', 'Milpa Foods');
  INSERT INTO t113 VALUES ('name', v);
  SELECT * INTO n FROM core.fn_activation_needs('00000000-0000-0000-0000-000000113e01');
  ASSERT n.corrections_open = 1 AND NOT n.certificate_confirmed AND NOT n.ready, 'an open correction holds activation';
  code := '';
  BEGIN PERFORM core.fn_certificate_confirm('00000000-0000-0000-0000-000000113e01'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '55000', 'no tick while a correction is open: ' || code;
  code := '';
  BEGIN PERFORM core.fn_certificate_correction_open('00000000-0000-0000-0000-000000113e01', 'mark_text_en', 'Other'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '55000', 'one open correction per field: ' || code;
  -- the certificate does not bear it out: held, and both sides are told
  ASSERT core.fn_certificate_correction_check(v, 'contradicts', 'MILPA', 'm', 50, 5) = 'held', 'not borne out: held';
  ASSERT (SELECT count(*) FROM core.fn_certificate_correction_alert(v) WHERE NOT staff) = 1, 'the person who entered it is told';
  ASSERT (SELECT mark_text_en FROM core.certificate_reading WHERE document_id = '00000000-0000-0000-0000-000000113d02') = 'Milpa', 'a held correction changes nothing';
  -- a date the certificate bears out: accepted, and the reading carries it
  v := core.fn_certificate_correction_open('00000000-0000-0000-0000-000000113e01', 'expiry_date', '2036-08-11');
  ASSERT core.fn_certificate_correction_check(v, 'supports', '11/08/2036') = 'accepted', 'borne out: accepted';
  ASSERT (SELECT expiry_date FROM core.certificate_reading WHERE document_id = '00000000-0000-0000-0000-000000113d02') = '2036-08-11', 'the reading carries the corrected date';
END $$;
-- a Viewer neither confirms nor corrects
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000113a02', true);
DO $$ DECLARE code text := ''; BEGIN
  BEGIN PERFORM core.fn_certificate_confirm('00000000-0000-0000-0000-000000113e01'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '42501', 'a Viewer does not confirm: ' || code;
  code := '';
  BEGIN PERFORM platform.fn_certificate_corrections(); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '42501', 'the staff queue is not for accounts: ' || code;
END $$;
RESET ROLE;
-- System Admin sees the held one and settles it
INSERT INTO core.app_user (id, account_id, email, name, role, status)
  SELECT '00000000-0000-0000-0000-000000113c01', a.id, 'sys@x113.test', 'Sys', 'company_admin', 'active' FROM core.account a WHERE a.is_staff LIMIT 1;
INSERT INTO platform.staff_role (user_id, role) SELECT '00000000-0000-0000-0000-000000113c01', 'system_admin' WHERE EXISTS (SELECT 1 FROM core.app_user WHERE id = '00000000-0000-0000-0000-000000113c01');
DO $$ DECLARE v uuid := (SELECT id FROM t113 WHERE k = 'name'); who record; code text := ''; BEGIN
  ASSERT (SELECT count(*) FROM platform.fn_certificate_corrections() WHERE id = v AND field = 'mark_text_en' AND corrected_value = 'Milpa Foods') = 1, 'the held correction is in the staff queue';
  ASSERT (SELECT file_name FROM platform.fn_certificate_correction_file(v)) = 'c.pdf', 'with its certificate';
  BEGIN PERFORM platform.fn_certificate_correction_settle(v, true, 'ok', '00000000-0000-0000-0000-000000113a01'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '42501', 'only a System Administrator settles: ' || code;
  IF EXISTS (SELECT 1 FROM core.app_user WHERE id = '00000000-0000-0000-0000-000000113c01') THEN
    SELECT * INTO who FROM platform.fn_certificate_correction_settle(v, true, 'the certificate says so', '00000000-0000-0000-0000-000000113c01');
    ASSERT who.email = 'adm@x113.test', 'the person who entered it is told the outcome';
    ASSERT (SELECT mark_text_en FROM core.certificate_reading WHERE document_id = '00000000-0000-0000-0000-000000113d02') = 'Milpa Foods', 'accepted by staff: the reading carries it';
    ASSERT (SELECT mark_text ->> 'en' FROM core.record WHERE id = '00000000-0000-0000-0000-000000113e01') = 'Milpa', 'staff did not write to the record';
    ASSERT (SELECT count(*) FROM platform.fn_certificate_corrections() WHERE id = v) = 0, 'and it left the queue';
  END IF;
  ASSERT (SELECT sum(readings) FROM platform.fn_certificate_reader_usage()) >= 1 AND (SELECT sum(checks) FROM platform.fn_certificate_reader_usage()) >= 1, 'the reader''s use is counted';
END $$;
ROLLBACK;
\echo ALL 0113 TESTS PASSED
