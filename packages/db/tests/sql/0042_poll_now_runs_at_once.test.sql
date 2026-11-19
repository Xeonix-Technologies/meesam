-- Tests for migration 0042: a staff "poll now" queues the fetch job at once; the worker's own bookkeeping does not.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t42.lead', platform.fn_staff_invite('lead@x42.test', 'Lead', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'lead@x42.test';
CREATE TEMP TABLE _s AS SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
DELETE FROM platform.job WHERE kind = 'watch.fetch';

SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  PERFORM watch.fn_fetch_failed((SELECT id FROM _s), NULL, NULL, 'u', 'discover', 'timeout');
  PERFORM watch.fn_fetch_polled((SELECT id FROM _s), 10, 0);
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.fetch') = 0, 'the worker''s own updates queue nothing'; END $$;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t42.lead'), true);
DO $$ BEGIN
  PERFORM watch.fn_source_poll_now((SELECT id FROM _s));
  PERFORM watch.fn_source_poll_now((SELECT id FROM _s));
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.fetch' AND status = 'queued' AND run_at <= now()) = 1, 'one fetch job, due now, however often the button is pressed'; END $$;
ROLLBACK;
\echo ALL 0042 TESTS PASSED
