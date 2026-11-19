-- Tests for migration 0039: acknowledge, assign, and escalation of unacknowledged deadlines.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000039a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000039b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000039a9', 'owner_company', '{"en": "Stranger"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000039c0', '00000000-0000-0000-0000-0000000039a0', 'adm@x39.test', 'Adm', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000039c1', '00000000-0000-0000-0000-0000000039a0', 'mgr@x39.test', 'Mgr', 'tm_manager', 'active'),
  ('00000000-0000-0000-0000-0000000039c2', '00000000-0000-0000-0000-0000000039b0', 'aadm@x39.test', 'AAdm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000039c3', '00000000-0000-0000-0000-0000000039b0', 'agent@x39.test', 'Agent', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000039c9', '00000000-0000-0000-0000-0000000039a9', 'str@x39.test', 'Str', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000039f1', '00000000-0000-0000-0000-0000000039a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000039e1', '00000000-0000-0000-0000-0000000039f1', g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000039aa', '00000000-0000-0000-0000-0000000039a0', '00000000-0000-0000-0000-0000000039b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000039aa', '00000000-0000-0000-0000-0000000039e1');
DELETE FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000039e1';
INSERT INTO core.timer (id, record_id, family, timer_type, due_date, source, created_at) VALUES
  ('00000000-0000-0000-0000-000000003901', '00000000-0000-0000-0000-0000000039e1', 'statutory', 'oppose', DATE '2027-01-20', 'profile', TIMESTAMPTZ '2026-12-21 08:00+04');

-- the agency's agent acknowledges; the owner's manager assigns the deadline to the administrator; a stranger can do neither
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000039b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000039c3', true);
SELECT core.fn_timer_acknowledge('00000000-0000-0000-0000-000000003901');
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000039a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000039c1', true);
SELECT core.fn_timer_assign('00000000-0000-0000-0000-000000003901', '00000000-0000-0000-0000-0000000039c0');
DO $$
DECLARE bad boolean := false;
BEGIN
  ASSERT (SELECT assigned_user_id = '00000000-0000-0000-0000-0000000039c0' AND acknowledged_at IS NULL FROM core.timer_ack), 'the owner sees its own row: assigned, not acknowledged';
  ASSERT (SELECT count(*) FROM core.timer_ack) = 1, 'and not the agency''s row';
  BEGIN PERFORM core.fn_timer_assign('00000000-0000-0000-0000-000000003901', '00000000-0000-0000-0000-0000000039c3'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'a deadline is assigned to a user of one''s own account only';
  bad := false;
  BEGIN INSERT INTO core.timer_ack (timer_id, record_id, account_id) VALUES ('00000000-0000-0000-0000-000000003901', '00000000-0000-0000-0000-0000000039e1', '00000000-0000-0000-0000-0000000039a0'); EXCEPTION WHEN insufficient_privilege THEN bad := true; END;
  ASSERT bad, 'the app role cannot write acknowledgements directly';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000039a9', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000039c9', true);
DO $$
DECLARE bad boolean := false;
BEGIN
  BEGIN PERFORM core.fn_timer_acknowledge('00000000-0000-0000-0000-000000003901'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'an account that does not reach the trademark cannot acknowledge its deadline';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE table_name = 'timer_ack' AND record_id = '00000000-0000-0000-0000-0000000039e1') = 2, 'both actions are audited';
  ASSERT (SELECT count(*) FROM core.record_edit WHERE table_name = 'timer_ack' AND record_id = '00000000-0000-0000-0000-0000000039e1') >= 2, 'and shown on the record';
END $$;
DELETE FROM platform.notification WHERE record_id = '00000000-0000-0000-0000-0000000039e1';

-- 13 Jan: 7 days remain. The owner has not acknowledged: its administrator is told. The agency acknowledged: nobody there is.
DO $$ BEGIN
  ASSERT core.fn_reminders_escalate(TIMESTAMPTZ '2027-01-13 09:00+04') = 1, 'at 7 days: one e-mail, to the owner''s administrator';
  ASSERT (SELECT user_id = '00000000-0000-0000-0000-0000000039c0' AND point = 'esc7' AND (payload ->> 'unack')::boolean FROM platform.notification WHERE channel = 'email'), 'marked unacknowledged';
  ASSERT core.fn_reminders_escalate(TIMESTAMPTZ '2027-01-14 09:00+04') = 0, 'once per step';
END $$;
-- 17 Jan: 3 days remain. The ordinary 3-day reminder is written first; escalation marks the owner's two instead of adding more.
DO $$
DECLARE n integer;
BEGIN
  PERFORM core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-17 09:00+04');
  n := core.fn_reminders_escalate(TIMESTAMPTZ '2027-01-17 09:05+04');
  ASSERT n = 2, format('at 3 days: the owner''s two waiting reminders are marked, got %s', n);
  ASSERT (SELECT count(*) FROM platform.notification WHERE channel = 'email' AND point = 'd3' AND (payload ->> 'unack')::boolean
            AND user_id IN ('00000000-0000-0000-0000-0000000039c0', '00000000-0000-0000-0000-0000000039c1')) = 2, 'every user of the owner account, marked';
  ASSERT (SELECT count(*) FROM platform.notification WHERE channel = 'email' AND point = 'd3' AND COALESCE((payload ->> 'unack')::boolean, false)
            AND account_id = '00000000-0000-0000-0000-0000000039b0') = 0, 'the agency acknowledged: its reminders are not marked';
  ASSERT (SELECT count(*) FROM platform.notification WHERE channel = 'email' AND point = 'esc3') = 0, 'no second e-mail the same day';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.fn_reminder_mails_take(100) WHERE unack) = 3, 'the worker is told which reminders are unacknowledged (one at 7 days, two at 3)';
END $$;
RESET ROLE;
-- once the owner acknowledges, nothing more escalates
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000039a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000039c0', true);
SELECT core.fn_timer_acknowledge('00000000-0000-0000-0000-000000003901');
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT acknowledged_by_user_id = '00000000-0000-0000-0000-0000000039c0' AND assigned_user_id = '00000000-0000-0000-0000-0000000039c0' FROM core.timer_ack WHERE account_id = '00000000-0000-0000-0000-0000000039a0'), 'acknowledged; the assignment stays';
END $$;
SELECT 'ALL 0039 TESTS PASSED' AS result;
ROLLBACK;
