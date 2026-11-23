-- Tests for migration 0084: two-step sign-in is offered after signing in (as amended by 0085: until "don't ask me again").
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000084a1', 'owner_individual', '{"en": "Owner EightyFour"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status, locale) VALUES
  ('00000000-0000-0000-0000-0000000084b1', '00000000-0000-0000-0000-0000000084a1', 'o84@x84.test', 'Owner 84', 'company_admin', 'active', 'en'),
  ('00000000-0000-0000-0000-0000000084b2', '00000000-0000-0000-0000-0000000084a1', 'p84@x84.test', 'Invited 84', 'tm_manager', 'invited', 'en'),
  ('00000000-0000-0000-0000-0000000084b3', '00000000-0000-0000-0000-0000000084a1', 'q84@x84.test', 'Chose 84', 'tm_manager', 'active', 'en');
UPDATE core.app_user SET two_factor_choice = false WHERE id = '00000000-0000-0000-0000-0000000084b3';
DO $$ DECLARE staff uuid; BEGIN
  ASSERT core.fn_2fa_ask('00000000-0000-0000-0000-0000000084b1'), 'a login that has not chosen is asked';
  ASSERT NOT core.fn_2fa_ask('00000000-0000-0000-0000-0000000084b2'), 'not before the invitation is taken up';
  -- (0085: a login that already chose is asked too)
  ASSERT NOT core.fn_2fa_ask('00000000-0000-0000-0000-0000000084ff'), 'an unknown login: no';
  -- the answer is recorded for the signed-in user only, and once
  PERFORM set_config('meesam.account_id', '00000000-0000-0000-0000-0000000084a1', true);
  PERFORM set_config('meesam.user_id', '00000000-0000-0000-0000-0000000084b1', true);
  PERFORM core.sp_2fa_asked();
  ASSERT NOT core.fn_2fa_ask('00000000-0000-0000-0000-0000000084b1'), 'asked once';
  ASSERT (SELECT two_factor_asked_at IS NULL FROM core.app_user WHERE id = '00000000-0000-0000-0000-0000000084b3'), 'nobody else is marked';
  -- a staff login is asked even though its second step is always on (by e-mail or by app); not once the app is set up
  staff := platform.fn_staff_invite('s84@x84.test', 'Staff 84', 'watch_lead');
  UPDATE core.app_user SET status = 'active', two_factor_choice = true WHERE id = staff;
  ASSERT core.fn_2fa_ask(staff), 'staff: asked which way';
  UPDATE core.app_user SET totp_enabled_at = now(), totp_secret = 'x' WHERE id = staff;
  ASSERT NOT core.fn_2fa_ask(staff), 'with the app set up there is nothing to ask';
END $$;
ROLLBACK;
\echo ALL 0084 TESTS PASSED
