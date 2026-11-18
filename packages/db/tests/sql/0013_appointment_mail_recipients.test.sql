-- Tests for migration 0013: the other side's e-mail recipients, for parties to the appointment only.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000013a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000013b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000013c0', 'owner_company', '{"en": "Stranger"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000013b0', 'adm@x13.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000013b0', 'agt@x13.test', 'Agt', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000013b0', 'vwr@x13.test', 'Vwr', 'viewer', 'active'),
  ('00000000-0000-0000-0000-0000000013b0', 'sus@x13.test', 'Sus', 'agent', 'suspended');
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by)
VALUES ('00000000-0000-0000-0000-0000000013d0', '00000000-0000-0000-0000-0000000013a0', '00000000-0000-0000-0000-0000000013b0', 'requested', 'owner');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000013a0', true);
DO $$ BEGIN
  ASSERT (SELECT string_agg(email::text, ',' ORDER BY email) FROM core.fn_appointment_recipients('00000000-0000-0000-0000-0000000013d0')) = 'adm@x13.test,agt@x13.test',
    'active administrator and agent of the other side; no viewer, no suspended user';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000013c0', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM * FROM core.fn_appointment_recipients('00000000-0000-0000-0000-0000000013d0'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an account outside the appointment gets nothing';
END $$;
RESET ROLE;
SELECT 'ALL 0013 TESTS PASSED' AS result;
ROLLBACK;
