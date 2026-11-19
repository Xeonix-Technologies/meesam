-- Tests for migration 0037: preferences, Important reminders held for the summary, and the daily summary itself.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000037a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000037b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000037c0', '00000000-0000-0000-0000-0000000037a0', 'adm@x37.test', 'Adm', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000037c1', '00000000-0000-0000-0000-0000000037a0', 'mgr@x37.test', 'Mgr', 'tm_manager', 'active'),
  ('00000000-0000-0000-0000-0000000037c2', '00000000-0000-0000-0000-0000000037b0', 'agent@x37.test', 'Agent', 'agent', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000037f1', '00000000-0000-0000-0000-0000000037a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000037e1', '00000000-0000-0000-0000-0000000037f1', g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000037aa', '00000000-0000-0000-0000-0000000037a0', '00000000-0000-0000-0000-0000000037b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000037aa', '00000000-0000-0000-0000-0000000037e1');
DELETE FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000037e1';
DELETE FROM platform.notification WHERE record_id = '00000000-0000-0000-0000-0000000037e1';
INSERT INTO core.timer (id, record_id, family, timer_type, due_date, source, created_at) VALUES
  ('00000000-0000-0000-0000-000000003701', '00000000-0000-0000-0000-0000000037e1', 'statutory', 'expiry', DATE '2027-09-10', 'profile', TIMESTAMPTZ '2026-12-01 08:00+04'),
  ('00000000-0000-0000-0000-000000003702', '00000000-0000-0000-0000-0000000037e1', 'reminder', 'renewal_window_reminder_6m', DATE '2027-03-10', 'profile', TIMESTAMPTZ '2026-12-01 08:00+04'),
  ('00000000-0000-0000-0000-000000003703', '00000000-0000-0000-0000-0000000037e1', 'statutory', 'oppose', DATE '2027-03-13', 'profile', TIMESTAMPTZ '2026-12-01 08:00+04');

-- the manager chooses the daily summary for Important reminders; the administrator switches the summary of changes off
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000037a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000037c1', true);
DO $$ BEGIN
  ASSERT (SELECT NOT important_digest AND routine_digest FROM core.fn_notify_pref()), 'defaults: Important at once, summary of changes on';
  PERFORM core.fn_notify_pref_set(true, true);
  ASSERT (SELECT important_digest FROM core.fn_notify_pref()), 'saved';
END $$;
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000037c0', true);
SELECT core.fn_notify_pref_set(false, false);
RESET ROLE;

-- 10 Mar 2027: an Important reminder (renewal, 6 months) and a Critical one (opposition, 3 days) fall due
SELECT core.fn_reminders_materialise(TIMESTAMPTZ '2027-03-10 09:00+04');
-- and the agency changed the record twice
INSERT INTO platform.notification (account_id, channel, kind, record_id, created_at) VALUES
  ('00000000-0000-0000-0000-0000000037a0', 'in_app', 'record_edited', '00000000-0000-0000-0000-0000000037e1', TIMESTAMPTZ '2027-03-09 15:00+04'),
  ('00000000-0000-0000-0000-0000000037a0', 'in_app', 'record_edited', '00000000-0000-0000-0000-0000000037e1', TIMESTAMPTZ '2027-03-09 16:00+04');

SET LOCAL ROLE meesam_worker;
DO $$
DECLARE n integer;
BEGIN
  -- sent at once: Critical to all three users, Important to the two who did not choose the summary
  SELECT count(*) INTO n FROM platform.fn_reminder_mails_take(100);
  ASSERT n = 5, format('3 critical + 2 important at once, got %s', n);
  -- before the summary hour nothing is due
  ASSERT (SELECT count(*) FROM platform.fn_digest_take(TIMESTAMPTZ '2027-03-10 03:00+00', 4)) = 0, 'not before the summary hour';
END $$;
CREATE TEMP TABLE d37 AS SELECT * FROM platform.fn_digest_take(TIMESTAMPTZ '2027-03-10 05:00+00', 4);
DO $$ BEGIN
  -- the manager: the held Important reminder and the trademark changed twice; the administrator switched changes off and has nothing held
  ASSERT (SELECT count(*) FROM d37 WHERE email = 'mgr@x37.test' AND item = 'reminder' AND timer_type = 'renewal_window_reminder_6m' AND days = 184) = 1, 'the held Important reminder is in the manager''s summary';
  ASSERT (SELECT changes FROM d37 WHERE email = 'mgr@x37.test' AND item = 'changes') = 2, 'with the trademark changed twice';
  ASSERT (SELECT count(*) FROM d37 WHERE email = 'adm@x37.test') = 0, 'nothing for a user who switched the summary of changes off';
  ASSERT (SELECT count(*) FROM d37 WHERE email = 'agent@x37.test') = 0, 'nothing for the agency: the changes were its own';
  ASSERT (SELECT count(*) FROM platform.fn_digest_take(TIMESTAMPTZ '2027-03-10 09:00+00', 4)) = 0, 'one summary a day';
  ASSERT (SELECT count(*) FROM platform.fn_reminder_mails_take(100)) = 0, 'the held reminder was logged as sent with the summary';
END $$;
RESET ROLE;
-- the next day only new changes count
INSERT INTO platform.notification (account_id, channel, kind, record_id, created_at) VALUES
  ('00000000-0000-0000-0000-0000000037a0', 'in_app', 'record_edited', '00000000-0000-0000-0000-0000000037e1', TIMESTAMPTZ '2027-03-10 12:00+00');
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  ASSERT (SELECT changes FROM platform.fn_digest_take(TIMESTAMPTZ '2027-03-11 05:00+00', 4) WHERE email = 'mgr@x37.test' AND item = 'changes') = 1, 'the next summary counts only what is new';
END $$;
RESET ROLE;
SELECT 'ALL 0037 TESTS PASSED' AS result;
ROLLBACK;
