-- Tests for migration 0077: a signed-in user leaves feedback; staff read it; another account does not.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000077a1', 'owner_individual', '{"en": "Owner SeventySeven"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000077a2', 'owner_individual', '{"en": "Other SeventySeven"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000077b1', '00000000-0000-0000-0000-0000000077a1', 'u@x77.test', 'User', 'company_admin', 'active');
SET LOCAL ROLE meesam_app;
DO $$ DECLARE refused integer := 0; BEGIN
  BEGIN PERFORM platform.fn_feedback_add('The calendar is useful', '/en/calendar', 'en'); EXCEPTION WHEN insufficient_privilege THEN refused := refused + 1; END;
  PERFORM set_config('meesam.account_id', '00000000-0000-0000-0000-0000000077a1', true);
  PERFORM set_config('meesam.user_id', '00000000-0000-0000-0000-0000000077b1', true);
  BEGIN PERFORM platform.fn_feedback_add('  hi ', NULL, 'en'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 2, 'feedback needs a signed-in user and a few words';
  PERFORM platform.fn_feedback_add(' The calendar is useful ', '/en/calendar', 'en');
  ASSERT (SELECT count(*) FROM platform.feedback WHERE body = 'The calendar is useful' AND user_id = '00000000-0000-0000-0000-0000000077b1' AND page = '/en/calendar') = 1, 'stored with the account and user of the session';
  PERFORM set_config('meesam.account_id', '00000000-0000-0000-0000-0000000077a2', true);
  ASSERT (SELECT count(*) FROM platform.feedback) = 0, 'another account does not see it';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.feedback WHERE body = 'The calendar is useful') = 1, 'staff read feedback'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0077 TESTS PASSED
