-- Tests for migration 0011: users and roles inside an account; the app role cannot write user rows directly.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000011a0', 'owner_company', '{"en": "Co"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000011b0', 'owner_company', '{"en": "Other"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status, password_hash) VALUES
  ('00000000-0000-0000-0000-0000000011a1', '00000000-0000-0000-0000-0000000011a0', 'admin@co.test', 'Admin', 'company_admin', 'active', 'h1'),
  ('00000000-0000-0000-0000-0000000011a2', '00000000-0000-0000-0000-0000000011a0', 'mgr@co.test', 'Manager', 'tm_manager', 'active', 'h2'),
  ('00000000-0000-0000-0000-0000000011b1', '00000000-0000-0000-0000-0000000011b0', 'admin@other.test', 'Other', 'company_admin', 'active', 'h3');
CREATE TEMP TABLE t11 (id uuid); GRANT ALL ON t11 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- a trademark manager: cannot promote itself, cannot read hashes, cannot invite
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000011a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000011a2', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN UPDATE core.app_user SET role = 'company_admin' WHERE id = '00000000-0000-0000-0000-0000000011a2';
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a user cannot change a role directly';
  denied := false;
  BEGIN PERFORM password_hash FROM core.app_user; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'password hashes are not readable';
  denied := false;
  BEGIN INSERT INTO core.app_user (account_id, email, name, role) VALUES ('00000000-0000-0000-0000-0000000011a0', 'x@co.test', 'X', 'company_admin');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a user row cannot be inserted directly';
  denied := false;
  BEGIN PERFORM core.fn_user_invite('new@co.test', 'New', 'tm_manager'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'only the administrator invites';
  ASSERT core.fn_my_password_hash() = 'h2', 'own hash through the function';
  UPDATE core.app_user SET name = 'Renamed' WHERE account_id = '00000000-0000-0000-0000-0000000011a0';
  ASSERT (SELECT count(*) FROM core.app_user WHERE name = 'Renamed') = 1, 'a user renames only itself';
  ASSERT (SELECT count(*) FROM core.app_user) = 2, 'users of the own account only';
END $$;

-- the administrator invites, the invitation is accepted, roles and status change
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000011a1', true);
INSERT INTO t11 SELECT core.fn_user_invite('new@co.test', ' New ', 'tm_manager', 'ar');
DO $$
DECLARE denied boolean := false; v uuid := (SELECT id FROM t11);
BEGIN
  ASSERT (SELECT status = 'invited' AND name = 'New' AND locale = 'ar' FROM core.app_user WHERE id = v), 'invited';
  ASSERT core.fn_user_invited(v) = v, 'open invitation';
  BEGIN PERFORM core.fn_user_invite('admin@other.test', 'Taken', 'tm_manager'); EXCEPTION WHEN unique_violation THEN denied := true; END;
  ASSERT denied, 'an e-mail of another account is refused';
  denied := false;
  BEGIN PERFORM core.fn_user_invite('v@co.test', 'V', 'viewer'); EXCEPTION WHEN check_violation THEN denied := true; END;
  ASSERT denied, 'an owner company has no viewer role';
  denied := false;
  BEGIN PERFORM core.fn_user_set_role('00000000-0000-0000-0000-0000000011a1', 'tm_manager'); EXCEPTION WHEN check_violation THEN denied := true; END;
  ASSERT denied, 'the last administrator keeps the role';
  denied := false;
  BEGIN PERFORM core.fn_user_set_status('00000000-0000-0000-0000-0000000011a1', 'suspended'); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'no self-suspension';
  denied := false;
  BEGIN PERFORM core.fn_user_set_role('00000000-0000-0000-0000-0000000011b1', 'tm_manager'); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'no reach into another account';
END $$;
RESET ROLE;
INSERT INTO core.verification_token (user_id, purpose, token_hash, expires_at) SELECT id, 'invite', '\x11aa', now() + interval '1 day' FROM t11;
INSERT INTO core.session (user_id, account_id, token_hash, expires_at) VALUES ('00000000-0000-0000-0000-0000000011a2', '00000000-0000-0000-0000-0000000011a0', '\x11bb', now() + interval '1 day');
SET LOCAL ROLE meesam_app;
DO $$
DECLARE v uuid := (SELECT id FROM t11);
BEGIN
  ASSERT (SELECT user_name FROM core.fn_invite_preview('\x11aa')) = 'New', 'preview by token';
  ASSERT core.sp_accept_invite('\x11aa', 'h9') = v, 'invitation accepted';
  ASSERT core.sp_accept_invite('\x11aa', 'h10') IS NULL, 'a token works once';
  ASSERT (SELECT status = 'active' FROM core.app_user WHERE id = v), 'active after acceptance';
  PERFORM core.fn_user_set_role(v, 'company_admin');
  PERFORM core.fn_user_set_role('00000000-0000-0000-0000-0000000011a1', 'company_admin');
  PERFORM core.fn_user_set_status('00000000-0000-0000-0000-0000000011a2', 'suspended');
  ASSERT (SELECT status = 'suspended' FROM core.app_user WHERE id = '00000000-0000-0000-0000-0000000011a2'), 'suspended';
  PERFORM core.fn_user_set_status('00000000-0000-0000-0000-0000000011a2', 'active');
  PERFORM core.fn_user_set_status('00000000-0000-0000-0000-0000000011a2', 'removed');
  PERFORM core.fn_user_invite('mgr@co.test', 'Back', 'tm_manager');
  ASSERT (SELECT status = 'invited' FROM core.app_user WHERE id = '00000000-0000-0000-0000-0000000011a2'), 'a removed user of this account is invited again';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT revoked_at IS NOT NULL FROM core.session WHERE token_hash = '\x11bb'), 'suspension closes the sessions';
END $$;
SELECT 'ALL 0011 TESTS PASSED' AS result;
ROLLBACK;
