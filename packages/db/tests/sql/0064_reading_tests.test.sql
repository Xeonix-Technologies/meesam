-- Tests for migration 0064: who may ask for a reading test, and on what.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t64.lead', platform.fn_staff_invite('lead@x64.test', 'Lead SixtyFour', 'watch_lead')::text, false);
SELECT set_config('t64.rev', platform.fn_staff_invite('rev@x64.test', 'Rev SixtyFour', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x64.test', 'rev@x64.test');
CREATE TEMP TABLE _i AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       a AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T64-A', current_date - 2, 'AE/national_bulletin/T64-A_x.rar' FROM s RETURNING id),
       b AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T64-B', current_date - 1 FROM s RETURNING id)
  SELECT a.id AS stored, b.id AS not_stored, s.registry_id FROM a, b, s;
GRANT SELECT ON _i TO PUBLIC;
DELETE FROM platform.job WHERE kind = 'watch.read_test';

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t64.rev'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_read_test_request((SELECT stored FROM _i), 1, 2, 'claude-sonnet-5-5'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'only the watch operations lead may ask for a reading test';
END $$;
SELECT set_config('meesam.user_id', current_setting('t64.lead'), true);
DO $$ DECLARE refused integer := 0; v uuid; BEGIN
  BEGIN PERFORM watch.fn_read_test_request((SELECT not_stored FROM _i), 1, 2, 'claude-sonnet-5-5'); EXCEPTION WHEN no_data_found THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_read_test_request((SELECT stored FROM _i), 1, 2, 'x; drop'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 2, 'an issue with no stored file, or a model name that is not a name, is refused';
  v := watch.fn_read_test_request((SELECT stored FROM _i), 0, 9, 'claude-haiku-5-5');
  ASSERT (SELECT first_page = 1 AND pages = 5 AND status = 'queued' AND requested_by = current_setting('t64.lead')::uuid FROM watch.read_test WHERE id = v), 'page numbers are kept within bounds; at most five pages';
  ASSERT (SELECT auto_start FROM watch.read_test WHERE id = v), 'no first page given: Meesam is to find the first page of entries (0065)';
  v := watch.fn_read_test_request((SELECT stored FROM _i), 16, 3, 'claude-sonnet-5-5');
  ASSERT (SELECT first_page = 16 AND NOT auto_start FROM watch.read_test WHERE id = v), 'a first page given is kept';
  v := watch.fn_read_test_request((SELECT stored FROM _i), NULL, 3, 'claude-sonnet-5-5');
  ASSERT (SELECT first_page = 1 AND auto_start FROM watch.read_test WHERE id = v), 'an empty first page means automatic';
  ASSERT (SELECT fetch_spec -> 'read' ->> 'entry_marker' LIKE '%طالب التسجيل%' AND length(fetch_spec -> 'read' ->> 'notes') > 300 FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'), 'Qatar carries its reading profile as data';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.read_test' AND status = 'queued') = 3, 'each test is queued for the worker';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.published_mark m JOIN _i ON m.issue_id = _i.stored), 'asking for a test loads nothing among the published marks';
END $$;
UPDATE watch.reuse_register SET may_store = false WHERE registry_id = (SELECT registry_id FROM _i);
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t64.lead'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_read_test_request((SELECT stored FROM _i), 1, 1, 'claude-sonnet-5-5'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'nothing of a registry is processed against its re-use register';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0064 TESTS PASSED
