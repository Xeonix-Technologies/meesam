-- Tests for migration 0012: removing a user frees the e-mail address for another account.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000012a0', 'owner_company', '{"en": "Co A"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000012b0', 'agency_office', '{"en": "Office B"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status, password_hash) VALUES
  ('00000000-0000-0000-0000-0000000012a1', '00000000-0000-0000-0000-0000000012a0', 'a-admin@x12.test', 'A', 'company_admin', 'active', 'h'),
  ('00000000-0000-0000-0000-0000000012a2', '00000000-0000-0000-0000-0000000012a0', 'mover@x12.test', 'Mover', 'tm_manager', 'active', 'h'),
  ('00000000-0000-0000-0000-0000000012b1', '00000000-0000-0000-0000-0000000012b0', 'b-admin@x12.test', 'B', 'agency_admin', 'active', 'h');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000012b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000012b1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_user_invite('mover@x12.test', 'Mover', 'agent'); EXCEPTION WHEN unique_violation THEN denied := true; END;
  ASSERT denied, 'a live user of another account cannot be invited';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000012a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000012a1', true);
SELECT core.fn_user_set_status('00000000-0000-0000-0000-0000000012a2', 'removed');
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000012b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000012b1', true);
SELECT core.fn_user_invite('mover@x12.test', 'Mover', 'agent');
DO $$
BEGIN
  ASSERT (SELECT account_id FROM core.fn_user_for_login('mover@x12.test')) = '00000000-0000-0000-0000-0000000012b0', 'login finds the live user only';
  ASSERT core.fn_user_by_email('mover@x12.test') <> '00000000-0000-0000-0000-0000000012a2', 'look-up skips the removed row';
  PERFORM core.sp_login_attempt('mover@x12.test', false, NULL, 'test');
END $$;
RESET ROLE;
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.app_user WHERE email = 'mover@x12.test') = 2, 'the removed row is kept for history';
  BEGIN INSERT INTO core.app_user (account_id, email, name, role) VALUES ('00000000-0000-0000-0000-0000000012a0', 'mover@x12.test', 'Dup', 'tm_manager');
  EXCEPTION WHEN unique_violation THEN denied := true; END;
  ASSERT denied, 'one live user per e-mail';
  denied := false;
  BEGIN PERFORM core.sp_register_account('{"kind": "owner_individual", "name": {"en": "X"}, "country": "AE", "user": {"email": "mover@x12.test", "name": "X", "password_hash": "h"}}');
  EXCEPTION WHEN unique_violation THEN denied := true; END;
  ASSERT denied, 'sign-up refuses a live address';
  PERFORM core.sp_register_account('{"kind": "owner_individual", "name": {"en": "Y"}, "country": "AE", "user": {"email": "free@x12.test", "name": "Y", "password_hash": "h"}}');
END $$;
SELECT 'ALL 0012 TESTS PASSED' AS result;
ROLLBACK;
