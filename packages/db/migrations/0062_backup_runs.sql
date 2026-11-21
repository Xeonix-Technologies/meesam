-- 0062 — Second copy of the database, and its record (plan item A7; Founder ruling R15, 21 Nov 2026).
-- The worker writes a full copy of the database each night to a bucket with another company and region
-- (Cloudflare R2, EU jurisdiction: BACKUP_* variables), checks it, and from time to time restores it into a
-- scratch database to prove it can be restored. Every run is recorded here; the Meesam System Admin shows them
-- and can ask for a run now. Nothing about a customer is stored in this table: only sizes, counts and outcomes.
BEGIN;

CREATE TABLE platform.backup_run (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz NULL,
  ok            boolean NULL,                 -- NULL while running
  trigger       text NOT NULL DEFAULT 'nightly' CHECK (trigger IN ('nightly', 'requested')),
  requested_by  uuid NULL REFERENCES core.app_user(id),
  object_key    text NULL,
  bytes         bigint NULL,
  sha256        text NULL,
  entries       integer NULL,                 -- objects listed in the copy (tables, indexes, functions…)
  restore_ok    boolean NULL,                 -- NULL = no restore test in this run
  restore       jsonb NULL,                   -- {tables, counts: {live: {...}, restored: {...}}, seconds} or {error}
  error         text NULL,
  deleted_at    timestamptz NULL,             -- when the copy was removed under the retention rule
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON platform.backup_run (started_at DESC);
ALTER TABLE platform.backup_run ENABLE ROW LEVEL SECURITY;
CREATE POLICY backup_run_read ON platform.backup_run FOR SELECT TO meesam_staff, meesam_admin, meesam_worker USING (true);
CREATE POLICY backup_run_write ON platform.backup_run FOR ALL TO meesam_worker USING (true) WITH CHECK (true);
GRANT SELECT ON platform.backup_run TO meesam_staff, meesam_admin;
GRANT SELECT, INSERT, UPDATE ON platform.backup_run TO meesam_worker;

-- Is a nightly copy due? After the set hour (UTC), when no copy has succeeded in the last 20 hours and none is running.
CREATE FUNCTION platform.fn_backup_due(p_hour_utc integer DEFAULT 22, p_now timestamptz DEFAULT now()) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT extract(hour FROM p_now AT TIME ZONE 'UTC') >= p_hour_utc
     AND NOT EXISTS (SELECT 1 FROM platform.backup_run b
                      WHERE (b.ok AND b.started_at > p_now - interval '20 hours')
                         OR (b.ok IS NULL AND b.started_at > p_now - interval '2 hours'))
$$;

-- Retention: keep every copy for p_keep_days, then only the first good copy of each month for a year.
-- Returns the copies to delete now and marks them, so each is deleted once.
CREATE FUNCTION platform.fn_backup_expire(p_keep_days integer DEFAULT 35) RETURNS TABLE (id uuid, object_key text)
LANGUAGE sql AS $$
  WITH firsts AS (
    SELECT DISTINCT ON (date_trunc('month', b.started_at)) b.id FROM platform.backup_run b
     WHERE b.ok AND b.object_key IS NOT NULL ORDER BY date_trunc('month', b.started_at), b.started_at),
  gone AS (
    UPDATE platform.backup_run b SET deleted_at = now(), updated_at = now()
     WHERE b.ok AND b.object_key IS NOT NULL AND b.deleted_at IS NULL
       AND b.started_at < now() - make_interval(days => p_keep_days)
       AND (b.id NOT IN (SELECT f.id FROM firsts f) OR b.started_at < now() - interval '1 year')
    RETURNING b.id, b.object_key)
  SELECT g.id, g.object_key FROM gone g
$$;
REVOKE EXECUTE ON FUNCTION platform.fn_backup_expire(integer) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_backup_expire(integer), platform.fn_backup_due(integer, timestamptz) TO meesam_worker;

-- A system administrator asks for a copy now; the worker picks it up within seconds.
CREATE FUNCTION platform.fn_backup_request(p_restore_test boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform.staff_role r WHERE r.user_id = platform.current_user_id() AND r.role = 'system_admin') THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM platform.backup_run b WHERE b.ok IS NULL AND b.started_at > now() - interval '2 hours') THEN
    RAISE EXCEPTION 'a copy is already being made' USING ERRCODE = '55006';
  END IF;
  RETURN platform.enqueue_job('platform.backup',
    jsonb_build_object('requested', true, 'restore_test', p_restore_test, 'by', platform.current_user_id()), now(), 'platform.backup');
END $$;
REVOKE EXECUTE ON FUNCTION platform.fn_backup_request(boolean) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_backup_request(boolean) TO meesam_staff, meesam_admin;

COMMIT;
