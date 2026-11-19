-- Tests for migration 0040: acceptance of the legal documents is recorded once per version and is private.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000040e0', 'owner_individual', '{"en": "New"}', 'AE', 'pending_email');
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000040e1', 'owner_individual', '{"en": "Old"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status, created_at) VALUES
  ('00000000-0000-0000-0000-0000000040f0', '00000000-0000-0000-0000-0000000040e0', 'new@x40c.test', 'New', 'company_admin', 'invited', now()),
  ('00000000-0000-0000-0000-0000000040f1', '00000000-0000-0000-0000-0000000040e1', 'old@x40c.test', 'Old', 'company_admin', 'active', now() - interval '30 days');
UPDATE core.app_user SET created_at = now() - interval '30 days' WHERE id = '00000000-0000-0000-0000-0000000040f1';
SET LOCAL ROLE meesam_app;
DO $$
DECLARE bad boolean := false;
BEGIN
  -- at sign-up there is no session yet: accepted for the user just created
  ASSERT core.sp_record_consent('00000000-0000-0000-0000-0000000040f0', ARRAY['terms', 'acceptable-use', 'ai-and-watch', 'privacy'], 'v0.1-draft-2026-11-12', 'sign_up') = 4, 'four documents recorded';
  ASSERT core.sp_record_consent('00000000-0000-0000-0000-0000000040f0', ARRAY['terms'], 'v0.1-draft-2026-11-12', 'sign_up') = 0, 'the same version is recorded once';
  ASSERT core.sp_record_consent('00000000-0000-0000-0000-0000000040f0', ARRAY['terms'], 'v1.0', 'in_app') = 1, 'a new version is a new row';
  BEGIN PERFORM core.sp_record_consent('00000000-0000-0000-0000-0000000040f1', ARRAY['terms'], 'v1.0', 'sign_up'); EXCEPTION WHEN insufficient_privilege THEN bad := true; END;
  ASSERT bad, 'no acceptance can be written for a long-standing user without that user''s session';
  bad := false;
  BEGIN PERFORM core.sp_record_consent('00000000-0000-0000-0000-0000000040f0', ARRAY['something-else'], 'v1.0', 'sign_up'); EXCEPTION WHEN check_violation THEN bad := true; END;
  ASSERT bad, 'only known documents';
  bad := false;
  BEGIN UPDATE core.legal_acceptance SET version = 'x'; EXCEPTION WHEN insufficient_privilege THEN bad := true; END;
  ASSERT bad, 'the app role cannot change the record';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000040e1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000040f1', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.legal_acceptance) = 0, 'a user reads only their own acceptances';
  ASSERT core.sp_record_consent('00000000-0000-0000-0000-0000000040f1', ARRAY['terms'], 'v1.0', 'in_app') = 1, 'a signed-in user records their own';
END $$;
RESET ROLE;
SELECT 'ALL 0040 TESTS PASSED' AS result;
ROLLBACK;
