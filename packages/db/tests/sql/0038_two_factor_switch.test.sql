-- Tests for migration 0038: the user's own on/off switch for two-step sign-in; staff stay on.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000038a0', 'owner_company', '{"en": "Company"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000038c0', '00000000-0000-0000-0000-0000000038a0', 'adm@x38.test', 'Adm', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000038c1', '00000000-0000-0000-0000-0000000038a0', 'mgr@x38.test', 'Mgr', 'tm_manager', 'active');
SELECT platform.fn_staff_account();
INSERT INTO core.app_user (id, account_id, email, name, role, status)
  SELECT '00000000-0000-0000-0000-0000000038f1', id, 'staff@x38.test', 'Staff', 'company_admin', 'active' FROM core.account WHERE is_staff;
INSERT INTO platform.staff_role (user_id, role) VALUES ('00000000-0000-0000-0000-0000000038f1', 'system_admin');
DO $$ BEGIN
  ASSERT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000038c0')), 'default: on for a company administrator';
  ASSERT (SELECT NOT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000038c1')), 'default: off for a trademark manager';
END $$;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000038a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000038c0', true);
SELECT core.sp_2fa_opt(false);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000038c1', true);
SELECT core.sp_2fa_opt(true);
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT NOT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000038c0')), 'the administrator switched it off';
  ASSERT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000038c1')), 'the manager switched it on';
END $$;
-- a staff login cannot switch it off
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', (SELECT id::text FROM core.account WHERE is_staff), true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000038f1', true);
SELECT core.sp_2fa_opt(false);
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000038f1')), 'two-step sign-in stays on for a staff login';
END $$;
SELECT 'ALL 0038 TESTS PASSED' AS result;
ROLLBACK;
