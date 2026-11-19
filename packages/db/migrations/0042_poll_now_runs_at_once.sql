-- 0042 — "Poll now", "Resume" and closing an incident start the fetcher at once (Founder, staging test 19 Nov 2026:
-- waiting for the next ten-minute round is too slow). When a staff member makes a source due, the fetch job is
-- queued straight away; the worker picks a queued job up within seconds. The dedupe key keeps a single copy.
BEGIN;

CREATE FUNCTION watch.trg_source_due_now() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  PERFORM platform.enqueue_job('watch.fetch', '{}'::jsonb, now(), 'watch.fetch');
  RETURN NULL;
END $$;

CREATE TRIGGER source_due_now AFTER UPDATE OF next_poll_at ON watch.publication_source
  FOR EACH ROW WHEN (NEW.next_poll_at <= now() AND NEW.active AND NOT NEW.paused AND platform.current_user_id() IS NOT NULL)
  EXECUTE FUNCTION watch.trg_source_due_now();

COMMIT;
