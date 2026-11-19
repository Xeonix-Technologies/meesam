-- Tests for migration 0035: reminder points, recipients, idempotence, hand-over to the worker.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000035a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000035b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000035a9', 'owner_company', '{"en": "Stranger"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000035c0', '00000000-0000-0000-0000-0000000035a0', 'adm@x35.test', 'Adm', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000035c1', '00000000-0000-0000-0000-0000000035a0', 'off@x35.test', 'Off', 'tm_manager', 'suspended'),
  ('00000000-0000-0000-0000-0000000035c2', '00000000-0000-0000-0000-0000000035b0', 'agent@x35.test', 'Agent', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000035c9', '00000000-0000-0000-0000-0000000035a9', 'str@x35.test', 'Str', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000035f1', '00000000-0000-0000-0000-0000000035a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000035e1', '00000000-0000-0000-0000-0000000035f1', g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000035aa', '00000000-0000-0000-0000-0000000035a0', '00000000-0000-0000-0000-0000000035b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000035aa', '00000000-0000-0000-0000-0000000035e1');
DELETE FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000035e1';
-- "now" for the test: 10 Jan 2027, midday in Dubai
-- an opposition window that started 20 days ago and ends in 10 days; an expiry 8 months away with its 6-month reminder due in 2 months;
-- a clock created today that was already overdue; a clock waiting for the user to enter its date
INSERT INTO core.timer (id, record_id, family, timer_type, due_date, source, created_at) VALUES
  ('00000000-0000-0000-0000-000000003501', '00000000-0000-0000-0000-0000000035e1', 'statutory', 'oppose', DATE '2027-01-20', 'profile', TIMESTAMPTZ '2026-12-21 08:00+04'),
  ('00000000-0000-0000-0000-000000003502', '00000000-0000-0000-0000-0000000035e1', 'statutory', 'expiry', DATE '2027-09-10', 'profile', TIMESTAMPTZ '2026-12-21 08:00+04'),
  ('00000000-0000-0000-0000-000000003503', '00000000-0000-0000-0000-0000000035e1', 'reminder', 'renewal_window_reminder_6m', DATE '2027-03-10', 'profile', TIMESTAMPTZ '2026-12-21 08:00+04'),
  ('00000000-0000-0000-0000-000000003504', '00000000-0000-0000-0000-0000000035e1', 'statutory', 'appeal', DATE '2026-11-01', 'profile', TIMESTAMPTZ '2027-01-10 08:00+04');
INSERT INTO core.timer (id, record_id, family, timer_type, source, awaiting_user_entry) VALUES
  ('00000000-0000-0000-0000-000000003505', '00000000-0000-0000-0000-0000000035e1', 'statutory', 'counterstatement', 'profile', true);

DO $$
DECLARE n integer;
BEGIN
  n := core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-10 12:00+04');
  -- only the opposition clock has a point today (10 days remaining): 2 accounts in-app + 2 users by e-mail (the suspended user gets none)
  ASSERT n = 4, format('10 days before the opposition deadline: 4 notifications, got %s', n);
  ASSERT (SELECT count(*) FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000003501' AND point = 'd10' AND severity = 'critical' AND channel = 'email'
            AND user_id IN ('00000000-0000-0000-0000-0000000035c0', '00000000-0000-0000-0000-0000000035c2')) = 2, 'the administrator and the agency''s agent are e-mailed, critical';
  ASSERT (SELECT count(*) FROM platform.notification WHERE user_id = '00000000-0000-0000-0000-0000000035c1') = 0, 'a user who is not active receives nothing';
  ASSERT (SELECT count(*) FROM platform.notification WHERE account_id = '00000000-0000-0000-0000-0000000035a9') = 0, 'an account without access receives nothing';
  ASSERT (SELECT count(*) FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000003504') = 0, 'no reminder about a deadline that had passed before the clock existed';
  ASSERT (SELECT (payload ->> 'days')::int FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000003501' LIMIT 1) = 10, 'days remaining by the registry''s calendar';
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-10 18:00+04') = 0, 'a second run the same day writes nothing';
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-12 09:00+04') = 0, 'nor a run two days later (same point)';
  -- 3 days remaining, then the due day
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-17 09:00+04') = 4, '3 days remaining';
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-20 23:30+04') = 4, 'the due day, still the 20th in Dubai';
  ASSERT (SELECT count(DISTINCT point) FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000003501') = 3, 'd10, d3, due';
  -- the 6-month renewal reminder: 6 months from expiry is more than 30 days, so Important
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-03-10 09:00+04') = 4, 'the renewal reminder on its day';
  ASSERT (SELECT DISTINCT severity FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000003503') = 'important', 'a reminder 6 months ahead is Important';
  -- a clock met in the meantime no longer reminds
  UPDATE core.timer SET state = 'met', met_at = now() WHERE id = '00000000-0000-0000-0000-000000003502';
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-09-10 09:00+04') = 0, 'a clock that is no longer open does not remind';
END $$;

-- a clock that starts today reminds at start
INSERT INTO core.timer (id, record_id, family, timer_type, due_date, source, created_at) VALUES
  ('00000000-0000-0000-0000-000000003506', '00000000-0000-0000-0000-0000000035e1', 'statutory', 'pay_registration', DATE '2027-05-31', 'profile', TIMESTAMPTZ '2027-05-01 10:00+04');
DO $$ BEGIN
  ASSERT core.fn_reminders_materialise(TIMESTAMPTZ '2027-05-01 12:00+04') = 4, 'at the start of a 30-day clock';
  ASSERT (SELECT DISTINCT point FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000003506') = 'start', 'the start point';
END $$;

-- the worker takes the e-mails once; a failed one is recorded
SET LOCAL ROLE meesam_worker;
DO $$
DECLARE v uuid; n integer;
BEGIN
  SELECT count(*), (array_agg(id))[1] INTO n, v FROM platform.fn_reminder_mails_take(100);
  ASSERT n = 10, format('five points, two users each: 10 e-mails, got %s', n);
  ASSERT (SELECT count(*) FROM platform.fn_reminder_mails_take(100)) = 0, 'taken once';
  PERFORM platform.fn_notification_failed(v, 'provider said no');
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.notification WHERE channel = 'email' AND status = 'failed' AND last_error = 'provider said no') = 1, 'a failed send is on the log';
  ASSERT (SELECT count(*) FROM platform.notification WHERE channel = 'email' AND status = 'sent' AND sent_at IS NOT NULL) = 9, 'the others are logged as sent';
END $$;
SELECT 'ALL 0035 TESTS PASSED' AS result;
ROLLBACK;
