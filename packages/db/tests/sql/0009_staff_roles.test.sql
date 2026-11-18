-- Tests for migration 0009: staff roles are invisible to the app role and granted only through the admin procedure.
BEGIN;
SET client_min_messages = warning;
-- from 0025 a staff role is held only by a user of the staff account
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, is_staff) VALUES ('00000000-0000-0000-0000-00000000090a', 'owner_company', '{"en": "S"}', 'AE', now(), 'staff', true);
INSERT INTO core.account (id, kind, name, country) VALUES ('00000000-0000-0000-0000-00000000090b', 'agency_office', '{"en": "Pending agency"}', 'AE');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000090a1', '00000000-0000-0000-0000-00000000090a', 's@x.test', 'S', 'company_admin', 'active');
SET LOCAL ROLE meesam_admin;
CALL platform.sp_grant_staff('00000000-0000-0000-0000-0000000090a1', 'system_admin');
CALL platform.sp_grant_staff('00000000-0000-0000-0000-0000000090a1', 'system_admin');   -- idempotent
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT platform.fn_staff_roles('00000000-0000-0000-0000-0000000090a1') = ARRAY['system_admin'], 'role readable through the function';
  BEGIN PERFORM 1 FROM platform.staff_role; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the app role cannot read the table';
  denied := false;
  BEGIN CALL platform.sp_grant_staff('00000000-0000-0000-0000-0000000090a1', 'watch_lead'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the app role cannot grant a staff role';
  denied := false;
  BEGIN PERFORM 1 FROM platform.v_admin_account; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the app role cannot read the admin view';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.v_admin_account WHERE id = '00000000-0000-0000-0000-00000000090b') = 1, 'staff see accounts'; END $$;
CALL core.sp_review_account('00000000-0000-0000-0000-00000000090b', true, 'staff', '00000000-0000-0000-0000-0000000090a1', 'licence checked');
DO $$ BEGIN ASSERT (SELECT verification_status::text FROM platform.v_admin_account WHERE id = '00000000-0000-0000-0000-00000000090b') = 'verified', 'staff can review'; END $$;
RESET ROLE;
SELECT 'ALL 0009 TESTS PASSED' AS result;
ROLLBACK;
