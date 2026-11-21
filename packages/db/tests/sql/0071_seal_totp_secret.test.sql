-- Tests for migration 0071: a plain authenticator secret is replaced by its sealed form only during its owner's open sign-in.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000071a0', 'owner_company', '{"en": "Co SeventyOne"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000071a1', '00000000-0000-0000-0000-0000000071a0', 'mgr@x71.test', 'Mgr', 'tm_manager', 'active');
SET LOCAL ROLE meesam_app;
DO $$ DECLARE sealed text := 'v1.aXZpdml2aXZpdml2.Y2lwaGVydGV4dA.dGFndGFndGFndGFndGFn'; BEGIN
  PERFORM set_config('meesam.account_id', '00000000-0000-0000-0000-0000000071a0', true);
  PERFORM set_config('meesam.user_id', '00000000-0000-0000-0000-0000000071a1', true);
  PERFORM core.sp_totp_pending('JBSWY3DPEHPK3PXP');
  ASSERT core.sp_totp_confirm(100), 'an authenticator set up before the key existed is stored plain';
  ASSERT NOT core.sp_2fa_totp_seal('\x71aa', 'JBSWY3DPEHPK3PXP', sealed), 'without an open sign-in nothing is replaced';
  PERFORM core.sp_2fa_begin('00000000-0000-0000-0000-0000000071a1', '\x71aa');
  ASSERT NOT core.sp_2fa_totp_seal('\x71aa', 'WRONGWRONGWRONG', sealed), 'the old value must match';
  BEGIN PERFORM core.sp_2fa_totp_seal('\x71aa', 'JBSWY3DPEHPK3PXP', 'OTHERPLAINSECRET'); RAISE EXCEPTION 'a plain value was accepted as sealed'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  ASSERT core.sp_2fa_totp_seal('\x71aa', 'JBSWY3DPEHPK3PXP', sealed), 'during the owner''s open sign-in the plain secret is replaced by the sealed one';
  ASSERT (SELECT secret FROM core.fn_2fa_totp_secret('\x71aa')) = sealed, 'the server now reads the sealed form';
  ASSERT NOT core.sp_2fa_totp_seal('\x71aa', sealed, sealed), 'a sealed secret is not replaced again';
  ASSERT core.sp_2fa_totp_result('\x71aa', 101) = '00000000-0000-0000-0000-0000000071a1', 'the sign-in goes on as before';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0071 TESTS PASSED
