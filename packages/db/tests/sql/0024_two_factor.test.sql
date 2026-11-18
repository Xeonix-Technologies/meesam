-- Tests for migration 0024: who must give a second factor; e-mail code and authenticator checks; secrets unreadable.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000024a0', 'owner_company', '{"en": "Co"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000024c0', 'owner_individual', '{"en": "Person"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000024a1', '00000000-0000-0000-0000-0000000024a0', 'adm@x24.test', 'Adm', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000024a2', '00000000-0000-0000-0000-0000000024a0', 'mgr@x24.test', 'Mgr', 'tm_manager', 'active'),
  ('00000000-0000-0000-0000-0000000024c1', '00000000-0000-0000-0000-0000000024c0', 'one@x24.test', 'One', 'company_admin', 'active');
SET LOCAL ROLE meesam_app;
DO $$
DECLARE denied boolean := false; u uuid;
BEGIN
  ASSERT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000024a1')), 'a company administrator must';
  ASSERT NOT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000024a2')), 'a trademark manager may choose';
  ASSERT NOT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000024c1')), 'an individual owner may choose';
  BEGIN PERFORM totp_secret FROM core.app_user; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the authenticator secret is not readable';
  denied := false;
  BEGIN PERFORM 1 FROM core.login_challenge; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'challenges are not readable';

  -- e-mail code
  PERFORM core.sp_2fa_begin('00000000-0000-0000-0000-0000000024a1', '\x24aa');
  ASSERT (SELECT email FROM core.fn_2fa_challenge('\x24aa')) = 'adm@x24.test', 'the challenge names its user';
  ASSERT core.sp_2fa_email_code('\x24aa', '\x1111'), 'code recorded';
  ASSERT NOT core.sp_2fa_email_code('\x24aa', '\x2222'), 'not again within a minute';
  ASSERT core.sp_2fa_check_email('\x24aa', '\x9999') IS NULL, 'a wrong code is refused';
  ASSERT core.sp_2fa_check_email('\x24aa', '\x1111') = '00000000-0000-0000-0000-0000000024a1', 'the right code is accepted';
  ASSERT core.sp_2fa_check_email('\x24aa', '\x1111') IS NULL, 'once';

  -- six wrong tries close a challenge
  PERFORM core.sp_2fa_begin('00000000-0000-0000-0000-0000000024a1', '\x24bb');
  PERFORM core.sp_2fa_email_code('\x24bb', '\x1111');
  FOR i IN 1..6 LOOP PERFORM core.sp_2fa_check_email('\x24bb', '\x0000'); END LOOP;
  ASSERT core.sp_2fa_check_email('\x24bb', '\x1111') IS NULL, 'closed after six wrong tries';

  -- authenticator: set up in session, then used once per time step
  PERFORM set_config('meesam.account_id', '00000000-0000-0000-0000-0000000024a0', true);
  PERFORM set_config('meesam.user_id', '00000000-0000-0000-0000-0000000024a2', true);
  PERFORM core.sp_totp_pending('JBSWY3DPEHPK3PXP');
  ASSERT core.fn_totp_pending() = 'JBSWY3DPEHPK3PXP', 'the pending secret is shown to its owner';
  ASSERT core.sp_totp_confirm(100), 'confirmed';
  ASSERT (SELECT required AND totp FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000024a2')), 'with an authenticator set up, the second factor applies';
  PERFORM core.sp_2fa_begin('00000000-0000-0000-0000-0000000024a2', '\x24cc');
  ASSERT (SELECT secret FROM core.fn_2fa_totp_secret('\x24cc')) = 'JBSWY3DPEHPK3PXP', 'the server reads the secret for an open challenge';
  ASSERT core.sp_2fa_totp_result('\x24cc', 100) IS NULL, 'a code already used is refused';
  ASSERT core.sp_2fa_totp_result('\x24cc', 101) = '00000000-0000-0000-0000-0000000024a2', 'a fresh code is accepted';
  PERFORM core.sp_totp_remove();
  ASSERT NOT (SELECT totp FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000024a2')), 'removed';
  PERFORM core.sp_2fa_opt(true);
  ASSERT (SELECT required FROM core.fn_2fa_state('00000000-0000-0000-0000-0000000024a2')), 'opted in: the e-mail code applies';
END $$;
RESET ROLE;
SELECT 'ALL 0024 TESTS PASSED' AS result;
ROLLBACK;
