-- Tests for migration 0075: the lead reads a range of pages; without a layout, at most 12 pages.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t75.lead', platform.fn_staff_invite('lead@x75.test', 'Lead SeventyFive', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'lead@x75.test';
CREATE TEMP TABLE _i AS
  WITH q AS (SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'),
       e AS (SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'),
       a AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T75-A', current_date - 2, 'QA/x75.pdf' FROM q RETURNING id),
       c AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T75-C', current_date - 2, 'TR/x75.pdf' FROM e RETURNING id)
  SELECT a.id AS qa, c.id AS no_layout FROM a, c;
GRANT SELECT ON _i TO PUBLIC;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t75.lead'), true);
DO $$ DECLARE refused integer := 0; v uuid; BEGIN
  BEGIN PERFORM watch.fn_read_run_request((SELECT qa FROM _i), 'claude-sonnet-5-5', NULL, 5, NULL); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_read_run_request((SELECT qa FROM _i), 'claude-sonnet-5-5', NULL, 9, 5); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_read_run_request((SELECT no_layout FROM _i), 'claude-sonnet-5-5'); EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_read_run_request((SELECT no_layout FROM _i), 'claude-sonnet-5-5', NULL, 100, 112); EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := refused + 1; END;
  ASSERT refused = 4, 'a half-given or backward range is refused; without a layout neither the whole issue nor more than 12 pages can be read: ' || refused;
  v := watch.fn_read_run_request((SELECT no_layout FROM _i), 'claude-sonnet-5-5', NULL, 100, 111);
  ASSERT (SELECT from_page = 100 AND to_page = 111 AND status = 'queued' FROM watch.read_run WHERE id = v), 'twelve pages of an issue whose layout is not entered can be read';
  v := watch.fn_read_run_request((SELECT qa FROM _i), 'claude-sonnet-5-5', NULL, 20, 60);
  ASSERT (SELECT from_page = 20 AND to_page = 60 FROM watch.read_run WHERE id = v), 'with a layout a longer range is cut into its entries';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0075 TESTS PASSED
