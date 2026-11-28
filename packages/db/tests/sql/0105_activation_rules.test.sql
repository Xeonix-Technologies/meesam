-- Tests for migration 0105: what activation asks for, and marks added by hand.
BEGIN;
-- the tick of 0113 is not this test's subject: every reading counts as confirmed here
CREATE FUNCTION pg_temp.t_confirm() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.confirmed_at := now(); RETURN NEW; END $$;
CREATE TRIGGER zz_test_confirm BEFORE INSERT OR UPDATE ON core.certificate_reading FOR EACH ROW EXECUTE FUNCTION pg_temp.t_confirm();
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000105a00', 'owner_company', '{"en": "Owner 105"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000105a01', '00000000-0000-0000-0000-000000105a00', 'adm@x105.test', 'Adm', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000105f01', '00000000-0000-0000-0000-000000105a00', '{"en": "Pending"}', 'word'),
  ('00000000-0000-0000-0000-000000105f02', '00000000-0000-0000-0000-000000105a00', '{"en": "Registered"}', 'word'),
  ('00000000-0000-0000-0000-000000105f03', '00000000-0000-0000-0000-000000105a00', '{"en": "Seed"}', 'word'),
  ('00000000-0000-0000-0000-000000105f04', '00000000-0000-0000-0000-000000105a00', '{"en": "New filing"}', 'word');
-- set-up data written by the database owner keeps what it says
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-000000105e03', '00000000-0000-0000-0000-000000105f03', g.id, 'X105-3', 'existing', 'free_loaded', '{"en": "Seed"}' FROM registry.registry g WHERE g.code = 'AE';
DO $$ BEGIN
  ASSERT (SELECT activated_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000105e03'), 'a record written as set-up data is active';
END $$;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000105a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000105a01', true);
-- added by hand through the application: an application still pending, and a registered mark
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text, activated_at)
  SELECT '00000000-0000-0000-0000-000000105e01', '00000000-0000-0000-0000-000000105f01', g.id, 'X105-1', 'existing', 'free_loaded', '{"en": "Pending"}', now() FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, entry_mode, paid_state, mark_text, expiry_date)
  SELECT '00000000-0000-0000-0000-000000105e02', '00000000-0000-0000-0000-000000105f02', g.id, 'X105-2', 'R105-2', 'existing', 'free_loaded', '{"en": "Registered"}', DATE '2034-05-01' FROM registry.registry g WHERE g.code = 'AE';
-- a new filing made through Meesam is not touched by the rule
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-000000105e04', '00000000-0000-0000-0000-000000105f04', g.id, 'new_filing', 'free_new_pending', '{"en": "New filing"}' FROM registry.registry g WHERE g.code = 'AE';
DO $$ DECLARE c record; BEGIN
  ASSERT (SELECT activated_at IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000105e01'), 'added by hand: not active, whatever the statement says';
  ASSERT (SELECT activated_at IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000105e02'), 'added by hand, registered: not active';
  ASSERT (SELECT activated_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000105e04'), 'a new filing stays as before';
  ASSERT NOT core.fn_record_watched('00000000-0000-0000-0000-000000105e01'), 'and not watched';
  ASSERT (SELECT NOT needs_certificate AND NOT ready FROM core.fn_activation_needs('00000000-0000-0000-0000-000000105e01')), 'a pending application needs no certificate, only its image';
  ASSERT (SELECT needs_certificate AND NOT ready FROM core.fn_activation_needs('00000000-0000-0000-0000-000000105e02')), 'a registered mark needs its certificate';
  SELECT * INTO c FROM core.fn_activation_counts();
  ASSERT c.waiting = 2 AND c.ready = 0, format('two wait, none ready: %s %s', c.waiting, c.ready);
END $$;
RESET ROLE;
-- both receive their image; the registered one also a document that is not a certificate
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000105d01', '00000000-0000-0000-0000-000000105e01', 'IMG', 'AE/x105_1.png', 'm.png', 'image/png', 10, decode('00', 'hex'), '00000000-0000-0000-0000-000000105a00'),
  ('00000000-0000-0000-0000-000000105d02', '00000000-0000-0000-0000-000000105e02', 'IMG', 'AE/x105_2.png', 'm.png', 'image/png', 10, decode('01', 'hex'), '00000000-0000-0000-0000-000000105a00'),
  ('00000000-0000-0000-0000-000000105d03', '00000000-0000-0000-0000-000000105e02', 'POA', 'AE/x105_poa.pdf', 'p.pdf', 'application/pdf', 10, decode('02', 'hex'), '00000000-0000-0000-0000-000000105a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000105d01' WHERE id = '00000000-0000-0000-0000-000000105e01';
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000105d02' WHERE id = '00000000-0000-0000-0000-000000105e02';
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000105a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000105a01', true);
DO $$ DECLARE n integer; BEGIN
  ASSERT (SELECT ready FROM core.fn_activation_needs('00000000-0000-0000-0000-000000105e01')), 'the pending application is ready with its image alone';
  ASSERT (SELECT has_image AND NOT has_certificate AND NOT ready FROM core.fn_activation_needs('00000000-0000-0000-0000-000000105e02')), 'a power of attorney is not a certificate';
  n := core.fn_activation_request();
  ASSERT n = 1, format('only the ready one goes in the basket, got %s', n);
  ASSERT (SELECT activation_requested_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000105e01'), 'the pending application is in the basket';
END $$;
RESET ROLE;
-- a renewal certificate serves as the certificate
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000105d04', '00000000-0000-0000-0000-000000105e02', 'REN', 'AE/x105_ren.pdf', 'r.pdf', 'application/pdf', 10, decode('03', 'hex'), '00000000-0000-0000-0000-000000105a00');
-- 0106: read, and its expiry date is the record's
INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, application_no, confidence)
  VALUES ('00000000-0000-0000-0000-000000105d04', '00000000-0000-0000-0000-000000105e02', 'read', DATE '2034-05-01', 'x105-2', 0.9);
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000105a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000105a01', true);
DO $$ BEGIN
  ASSERT (SELECT ready FROM core.fn_activation_needs('00000000-0000-0000-0000-000000105e02')), 'ready with image and a renewal certificate read with the record''s expiry date';
  ASSERT core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000105e02']::uuid[]) = 1, 'and it goes in the basket';
  ASSERT (SELECT count(*) FROM core.fn_basket()) = 2, 'two in the basket';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0105 TESTS PASSED
