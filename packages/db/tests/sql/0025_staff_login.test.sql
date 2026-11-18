-- Tests for migration 0025: staff logins live in the staff account; cut-over removes staff roles from customer logins.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000025a0', 'owner_company', '{"en": "Customer"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status, password_hash) VALUES
  ('00000000-0000-0000-0000-0000000025a1', '00000000-0000-0000-0000-0000000025a0', 'old-admin@x25.test', 'Old', 'company_admin', 'active', 'h');
-- the grant made before this migration (on a customer login) is still there
ALTER TABLE platform.staff_role DISABLE TRIGGER staff_role_guard;
INSERT INTO platform.staff_role (user_id, role) VALUES ('00000000-0000-0000-0000-0000000025a1', 'system_admin');
ALTER TABLE platform.staff_role ENABLE TRIGGER staff_role_guard;
CREATE TEMP TABLE t25 (id uuid);
DO $$
DECLARE denied boolean := false; v uuid;
BEGIN
  BEGIN CALL platform.sp_grant_staff('00000000-0000-0000-0000-0000000025a1', 'watch_lead'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no new staff role on a customer login';
  v := platform.fn_staff_invite('staff@x25.test', 'Staff One', 'system_admin', '00000000-0000-0000-0000-0000000025a1');
  INSERT INTO t25 VALUES (v);
  ASSERT (SELECT a.is_staff AND u.status = 'invited' FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = v), 'an invited user of the staff account';
  ASSERT (SELECT count(*) FROM core.account WHERE is_staff) = 1, 'one staff account';
  ASSERT platform.fn_staff_roles('00000000-0000-0000-0000-0000000025a1') = ARRAY['system_admin'], 'the earlier administrator still works before the cut-over';
  ASSERT (SELECT count(*) FROM platform.v_admin_account WHERE id = (SELECT id FROM core.account WHERE is_staff)) = 0, 'the staff account is not listed as a customer';
  ASSERT (SELECT required FROM core.fn_2fa_state(v)), 'staff must give a second factor';
  denied := false;
  BEGIN PERFORM platform.fn_staff_invite('old-admin@x25.test', 'Dup', 'watch_lead'); EXCEPTION WHEN unique_violation THEN denied := true; END;
  ASSERT denied, 'a customer e-mail cannot become a staff login';
END $$;
-- the invited administrator accepts the invitation: cut-over
INSERT INTO core.verification_token (user_id, purpose, token_hash, expires_at) SELECT id, 'invite', '\x25aa', now() + interval '1 day' FROM t25;
SELECT core.sp_accept_invite('\x25aa', 'h2');
DO $$
DECLARE denied boolean := false; v uuid := (SELECT id FROM t25);
BEGIN
  ASSERT platform.fn_staff_roles(v) = ARRAY['system_admin'], 'the staff login holds the role';
  ASSERT platform.fn_staff_roles('00000000-0000-0000-0000-0000000025a1') = '{}', 'the customer login no longer does';
  BEGIN PERFORM platform.fn_staff_remove(v); EXCEPTION WHEN check_violation THEN denied := true; END;
  ASSERT denied, 'the last System Administrator stays';
  PERFORM platform.fn_staff_remove(platform.fn_staff_invite('second@x25.test', 'Second', 'watch_lead', v));
  ASSERT (SELECT status = 'removed' FROM core.app_user WHERE email = 'second@x25.test'), 'a staff member is removed';
END $$;
INSERT INTO core.session (user_id, account_id, token_hash, expires_at) SELECT id, (SELECT id FROM core.account WHERE is_staff), '\x25bb', now() + interval '1 day' FROM t25;
DO $$ BEGIN ASSERT (SELECT is_staff FROM core.fn_session('\x25bb')), 'the session says it is a staff login'; END $$;
SELECT 'ALL 0025 TESTS PASSED' AS result;
ROLLBACK;
