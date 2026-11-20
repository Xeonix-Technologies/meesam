-- Tests for migration 0041: the fetch stage's bookkeeping and the staff actions on it.
BEGIN;
SET client_min_messages = warning;
-- two staff logins in the staff account: a watch operations lead and a publication reviewer
SELECT set_config('t41.lead', platform.fn_staff_invite('lead@x41.test', 'Lead', 'watch_lead')::text, false);
SELECT set_config('t41.rev', platform.fn_staff_invite('rev@x41.test', 'Reviewer', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x41.test', 'rev@x41.test');
CREATE TEMP TABLE _s AS SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;

SET LOCAL ROLE meesam_worker;
DO $$
DECLARE src uuid := (SELECT id FROM _s); v uuid; n integer;
BEGIN
  ASSERT (SELECT count(*) FROM watch.fn_fetch_due()) = 1, 'only the UAE national stream has a location; the Madrid stream is read from the same archive';
  ASSERT (SELECT fetch_spec ->> 'container' FROM watch.fn_fetch_due()) = 'rar', 'the catalogue says the issue is an archive';
  ASSERT (SELECT days FROM watch.fn_source_window(src)) = 30, 'the period comes from the verified profile';
  ASSERT watch.fn_fetch_wanted(src, current_date - 10), 'an issue inside its window is wanted';
  ASSERT watch.fn_fetch_wanted(src, (now() AT TIME ZONE 'Asia/Dubai')::date - 30), 'the last day counts until 23:59 registry time';
  ASSERT NOT watch.fn_fetch_wanted(src, current_date - 40), 'an issue whose window has closed is not downloaded';
  ASSERT watch.fn_fetch_wanted(src, NULL), 'an undated issue is never skipped silently';

  -- a clean poll, then a stored issue
  PERFORM watch.fn_fetch_polled(src, 60, 1);
  ASSERT (SELECT count(*) FROM watch.fn_fetch_due()) = 0, 'not due again until the next poll';
  v := watch.fn_fetch_stored(src, '354', current_date - 2, 'https://x.test/354.rar', 'Bulletin 354', 'AE/national_bulletin/354_aa.rar', sha256('file-354'), 1000, 'rar');
  ASSERT v IS NOT NULL, 'stored';
  ASSERT (SELECT stored FROM watch.fn_fetch_known(src) WHERE issue_no = '354'), 'known as held';
  ASSERT (SELECT expected_next FROM watch.publication_schedule WHERE source_id = src) = current_date + 12, 'the next release is expected a fortnight after this one';
  -- the same file under another number is not stored twice, and is not asked for again
  ASSERT watch.fn_fetch_stored(src, '354 (2)', current_date - 2, 'https://x.test/354b.rar', 'Bulletin 354', 'k', sha256('file-354'), 1000, 'rar') IS NULL, 'duplicate by checksum';
  ASSERT (SELECT stored FROM watch.fn_fetch_known(src) WHERE issue_no = '354 (2)'), 'the duplicate link is remembered';
  ASSERT (SELECT count(*) FROM watch.publication_issue WHERE source_id = src AND object_key IS NOT NULL) = 1, 'one file held';

  -- failures: backoff, then an incident on the third in a row, with the window at risk
  n := watch.fn_fetch_failed(src, '355', current_date - 1, 'https://x.test/355.rar', 'download', 'HTTP 503');
  ASSERT n = 1 AND (SELECT next_poll_at FROM watch.publication_source WHERE id = src) BETWEEN now() + interval '4 minutes' AND now() + interval '6 minutes', 'first retry in 5 minutes';
  ASSERT NOT (SELECT stored FROM watch.fn_fetch_known(src) WHERE issue_no = '355'), 'a failed issue is tried again';
  PERFORM watch.fn_fetch_failed(src, '355', current_date - 1, 'https://x.test/355.rar', 'download', 'HTTP 503');
  ASSERT (SELECT count(*) FROM watch.fetch_incident WHERE source_id = src) = 0, 'no incident after two';
  n := watch.fn_fetch_failed(src, '355', current_date - 1, 'https://x.test/355.rar', 'shape', 'not a RAR archive');
  ASSERT n = 3 AND (SELECT earliest_window_end FROM watch.fetch_incident WHERE source_id = src AND closed_at IS NULL) = current_date + 29, 'incident opened with the earliest window at risk';
  PERFORM watch.fn_fetch_failed(src, NULL, NULL, 'https://x.test/list', 'discover', 'HTTP 500');
  ASSERT (SELECT count(*) FROM watch.fetch_incident WHERE source_id = src) = 1, 'one open incident per source';
  ASSERT (SELECT jsonb_array_length(recovery_log) FROM watch.publication_issue WHERE source_id = src AND issue_no = '355') = 3, 'every step is logged against the issue';
  -- recovery
  v := watch.fn_fetch_stored(src, '355', current_date - 1, 'https://x.test/355.rar', 'Bulletin 355', 'AE/national_bulletin/355_bb.rar', sha256('file-355'), 2000, 'rar');
  ASSERT (SELECT fetch_status FROM watch.publication_issue WHERE id = v) = 'retried' AND (SELECT outcome FROM watch.fetch_run WHERE issue_id = v ORDER BY started_at DESC, attempt DESC LIMIT 1) = 'recovered', 'a later success is recorded as recovered';
  ASSERT (SELECT failures FROM watch.publication_source WHERE id = src) = 0, 'failure count cleared';
  -- since 0050 the success closes the incident by itself; a new run of failures opens the one the lead closes below
  ASSERT (SELECT count(*) FROM watch.fetch_incident WHERE source_id = src AND closed_at IS NULL) = 0, 'the recovery closed the incident';
  FOR i IN 1..3 LOOP PERFORM watch.fn_fetch_failed(src, NULL, NULL, 'https://x.test/list', 'discover', 'HTTP 500'); END LOOP;
  ASSERT (SELECT count(*) FROM watch.fetch_incident WHERE source_id = src AND closed_at IS NULL) = 1, 'a new incident after three more failures';
END $$;
RESET ROLE;

-- staff: only the watch operations lead acts; the reviewer and a customer cannot
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t41.rev'), true);
DO $$
DECLARE src uuid := (SELECT id FROM _s); denied integer := 0;
BEGIN
  BEGIN PERFORM watch.fn_source_pause(src, true, 'x'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN UPDATE watch.publication_source SET paused = true WHERE id = src; EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN PERFORM watch.fn_fetch_stored(src, '1', NULL, 'u', 't', 'k', sha256('x'), 1, 'rar'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 3, 'a reviewer cannot pause, cannot write the table, and nobody on staff can hand in a file';
END $$;
SELECT set_config('meesam.user_id', current_setting('t41.lead'), true);
DO $$
DECLARE src uuid := (SELECT id FROM _s); inc uuid := (SELECT id FROM watch.fetch_incident WHERE closed_at IS NULL);
BEGIN
  PERFORM watch.fn_source_pause(src, true, 'site maintenance');
  ASSERT (SELECT paused AND paused_by = current_setting('t41.lead')::uuid FROM watch.publication_source WHERE id = src), 'paused by the lead';
  PERFORM watch.fn_source_pause(src, false);
  ASSERT (SELECT NOT paused AND next_poll_at <= now() FROM watch.publication_source WHERE id = src), 'resumed and due at once';
  PERFORM watch.fn_incident_close(inc, 'page works again');
  ASSERT (SELECT closed_by = current_setting('t41.lead')::uuid FROM watch.fetch_incident WHERE id = inc), 'closed by the lead';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE schema_name = 'watch' AND table_name = 'publication_source' AND user_id = current_setting('t41.lead')::uuid) = 3, 'pause, resume and the reset on closing the incident are audited to the person';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE schema_name = 'watch' AND table_name = 'publication_source' AND user_id IS NULL) = 0, 'the worker''s polling is not an audit event';
END $$;

-- a second role for a staff member; the only role cannot be taken away
SET LOCAL ROLE meesam_admin;
DO $$
DECLARE refused boolean := false;
BEGIN
  PERFORM platform.fn_staff_role_set(current_setting('t41.rev')::uuid, 'watch_lead', true, NULL);
  ASSERT platform.fn_staff_roles(current_setting('t41.rev')::uuid) = ARRAY['publication_reviewer', 'watch_lead'], 'two roles';
  PERFORM platform.fn_staff_role_set(current_setting('t41.rev')::uuid, 'publication_reviewer', false, NULL);
  BEGIN PERFORM platform.fn_staff_role_set(current_setting('t41.rev')::uuid, 'watch_lead', false, NULL); EXCEPTION WHEN check_violation THEN refused := true; END;
  ASSERT refused, 'the last role stays';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0041 TESTS PASSED
