-- Tests for migration 0014: the per-record thread; no direct writes; nothing for the agency after the appointment ends.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000014a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000014b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000014c0', 'agency_office', '{"en": "Stranger"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000014a1', '00000000-0000-0000-0000-0000000014a0', 'o@x14.test', 'Olive', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000014b1', '00000000-0000-0000-0000-0000000014b0', 'a@x14.test', 'Agnes', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000014b2', '00000000-0000-0000-0000-0000000014b0', 'v@x14.test', 'Vera', 'viewer', 'active'),
  ('00000000-0000-0000-0000-0000000014c1', '00000000-0000-0000-0000-0000000014c0', 's@x14.test', 'Sam', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000014f1', '00000000-0000-0000-0000-0000000014a0', '{"en": "m"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000014e1', '00000000-0000-0000-0000-0000000014f1', g.id, 'M1', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
CREATE TEMP TABLE t14 (id uuid); GRANT ALL ON t14 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014a1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000014e1', 'hello'); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'no holding agency: nobody to write to';
END $$;
INSERT INTO t14 SELECT core.fn_appointment_request('00000000-0000-0000-0000-0000000014b0', ARRAY['00000000-0000-0000-0000-0000000014e1']::uuid[], NULL);
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014b1', true);
SELECT core.fn_appointment_respond((SELECT id FROM t14), true);

-- owner writes; agency reads, answers; viewer and stranger cannot
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014a1', true);
SELECT core.fn_message_post('00000000-0000-0000-0000-0000000014e1', '  Please renew  ');
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT body FROM core.message) = 'Please renew', 'body trimmed and stored';
  BEGIN UPDATE core.message SET body = 'changed'; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a message cannot be edited';
  denied := false;
  BEGIN INSERT INTO core.message_thread (record_id, owner_account_id, agency_account_id) VALUES ('00000000-0000-0000-0000-0000000014e1', '00000000-0000-0000-0000-0000000014a0', '00000000-0000-0000-0000-0000000014c0');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a thread cannot be opened directly';
  ASSERT (SELECT string_agg(email::text, ',') FROM core.fn_message_recipients((SELECT id FROM core.message))) = 'a@x14.test', 'the agent is told, the viewer is not';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014b1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.message) = 1, 'the agency reads the thread';
  ASSERT (SELECT author_name FROM core.message) = 'Olive', 'with the author''s name, though it cannot read the owner''s users';
  ASSERT (SELECT count(*) FROM core.app_user WHERE name = 'Olive') = 0, 'the other account''s users stay hidden';
  ASSERT (SELECT agency_read_at IS NULL FROM core.message_thread), 'unread for the agency';
  PERFORM core.fn_thread_mark_read('00000000-0000-0000-0000-0000000014e1');
  ASSERT (SELECT agency_read_at IS NOT NULL FROM core.message_thread), 'marked read';
  PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000014e1', 'On it');
  BEGIN PERFORM * FROM core.fn_message_recipients((SELECT id FROM core.message WHERE body = 'Please renew')); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'recipients only for the author';
  PERFORM set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014b2', true);
  denied := false;
  BEGIN PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000014e1', 'viewer'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a viewer does not post';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014c0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014c1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.message) = 0, 'a stranger reads nothing';
  BEGIN PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000014e1', 'x'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a stranger does not post';
END $$;

-- the owner ends the appointment: the agency loses the thread, the owner keeps it
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014a1', true);
SELECT core.fn_appointment_end((SELECT id FROM t14));
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.message) = 2, 'the owner keeps the history'; END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000014b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000014b1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.message) = 0 AND (SELECT count(*) FROM core.message_thread) = 0, 'nothing for the agency after the end';
  BEGIN PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000014e1', 'late'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'and it cannot post';
END $$;
RESET ROLE;
SELECT 'ALL 0014 TESTS PASSED' AS result;
ROLLBACK;
