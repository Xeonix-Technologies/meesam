-- Tests for migration 0085: the two-step question is put at every sign-in until "don't ask me again".
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000085a1', 'owner_individual', '{"en": "Owner EightyFive"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status, locale) VALUES
  ('00000000-0000-0000-0000-0000000085b1', '00000000-0000-0000-0000-0000000085a1', 'o85@x85.test', 'Owner 85', 'company_admin', 'active', 'en'),
  ('00000000-0000-0000-0000-0000000085b2', '00000000-0000-0000-0000-0000000085a1', 'p85@x85.test', 'App 85', 'tm_manager', 'active', 'en');
UPDATE core.app_user SET two_factor_choice = false WHERE id = '00000000-0000-0000-0000-0000000085b1';
UPDATE core.app_user SET totp_enabled_at = now(), totp_secret = 'x' WHERE id = '00000000-0000-0000-0000-0000000085b2';
DO $$ BEGIN
  ASSERT core.fn_2fa_ask('00000000-0000-0000-0000-0000000085b1'), 'a login that chose before is asked all the same';
  ASSERT NOT core.fn_2fa_ask('00000000-0000-0000-0000-0000000085b2'), 'not with an authenticator app set up';
  PERFORM set_config('meesam.account_id', '00000000-0000-0000-0000-0000000085a1', true);
  PERFORM set_config('meesam.user_id', '00000000-0000-0000-0000-0000000085b1', true);
  PERFORM core.sp_2fa_opt(true);
  ASSERT core.fn_2fa_ask('00000000-0000-0000-0000-0000000085b1'), 'choosing does not stop the question';
  PERFORM core.sp_2fa_asked();
  ASSERT NOT core.fn_2fa_ask('00000000-0000-0000-0000-0000000085b1'), '"don''t ask me again" does';
END $$;
ROLLBACK;
\echo ALL 0085 TESTS PASSED
