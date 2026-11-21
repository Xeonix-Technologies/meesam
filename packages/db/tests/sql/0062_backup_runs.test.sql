-- Tests for migration 0062: when a nightly copy is due, who may ask for one, and the retention rule.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t62.admin', platform.fn_staff_invite('admin@x62.test', 'Admin SixtyTwo', 'system_admin')::text, false);
SELECT set_config('t62.lead', platform.fn_staff_invite('lead@x62.test', 'Lead SixtyTwo', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('admin@x62.test', 'lead@x62.test');
DELETE FROM platform.job WHERE kind = 'platform.backup';

DO $$ DECLARE d date := current_date; BEGIN
  ASSERT NOT platform.fn_backup_due(22, (d + time '21:59') AT TIME ZONE 'UTC'), 'not before the set hour';
  ASSERT platform.fn_backup_due(22, (d + time '22:05') AT TIME ZONE 'UTC'), 'due after the set hour when nothing was copied';
  INSERT INTO platform.backup_run (started_at, ok) VALUES ((d + time '22:06') AT TIME ZONE 'UTC', NULL);
  ASSERT NOT platform.fn_backup_due(22, (d + time '22:30') AT TIME ZONE 'UTC'), 'not while a copy is being made';
  UPDATE platform.backup_run SET ok = false, error = 'x';
  ASSERT platform.fn_backup_due(22, (d + time '23:00') AT TIME ZONE 'UTC'), 'a failed copy is tried again the same night';
  UPDATE platform.backup_run SET ok = true, error = NULL, object_key = 'db/a.dump';
  ASSERT NOT platform.fn_backup_due(22, (d + time '23:30') AT TIME ZONE 'UTC'), 'once copied, not again that night';
  ASSERT platform.fn_backup_due(22, (d + 1 + time '22:10') AT TIME ZONE 'UTC'), 'due again the next night';
  DELETE FROM platform.backup_run;
END $$;

-- who may ask for a copy now
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t62.lead'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM platform.fn_backup_request(); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'only a system administrator may ask for a copy';
END $$;
SELECT set_config('meesam.user_id', current_setting('t62.admin'), true);
SELECT platform.fn_backup_request(true);
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT payload ->> 'restore_test' = 'true' AND payload ->> 'by' = current_setting('t62.admin') FROM platform.job WHERE kind = 'platform.backup' AND status = 'queued'), 'the request is queued for the worker, with who asked';
END $$;
INSERT INTO platform.backup_run (ok) VALUES (NULL);
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t62.admin'), true);
DO $$ DECLARE busy boolean := false; BEGIN
  BEGIN PERFORM platform.fn_backup_request(); EXCEPTION WHEN object_in_use THEN busy := true; END;
  ASSERT busy, 'no second copy while one is being made';
END $$;
RESET ROLE;
DELETE FROM platform.backup_run;

-- retention: 35 days of every copy, then the first good copy of each month for a year
INSERT INTO platform.backup_run (started_at, finished_at, ok, object_key)
SELECT d, d, true, 'db/' || to_char(d, 'YYYYMMDD') || '.dump' FROM generate_series(now() - interval '100 days', now(), interval '1 day') d;
INSERT INTO platform.backup_run (started_at, finished_at, ok, object_key) VALUES (now() - interval '400 days', now() - interval '400 days', true, 'db/old.dump');
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE n integer; kept integer; months integer; BEGIN
  SELECT count(*) INTO n FROM platform.fn_backup_expire(35);
  SELECT count(*) INTO kept FROM platform.backup_run WHERE deleted_at IS NULL AND started_at < now() - interval '35 days';
  SELECT count(DISTINCT date_trunc('month', started_at)) INTO months FROM platform.backup_run WHERE started_at < now() - interval '35 days' AND started_at > now() - interval '1 year';
  ASSERT kept = months, 'older than 35 days, only one copy per month is kept: ' || kept || ' kept for ' || months || ' months';
  ASSERT (SELECT deleted_at IS NOT NULL FROM platform.backup_run WHERE object_key = 'db/old.dump'), 'a copy older than a year goes, even the first of its month';
  ASSERT (SELECT count(*) FROM platform.backup_run WHERE deleted_at IS NULL AND started_at >= now() - interval '35 days') >= 35, 'every copy of the last 35 days is kept';
  ASSERT (SELECT count(*) FROM platform.fn_backup_expire(35)) = 0, 'each copy is handed out for deletion once';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0062 TESTS PASSED
