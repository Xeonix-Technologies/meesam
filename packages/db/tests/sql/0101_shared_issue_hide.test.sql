-- Tests for migration 0101: the lead leaves one issue out of what accounts see, and puts it back.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t101.lead', platform.fn_staff_invite('lead@x101.test', 'Lead Person', 'watch_lead')::text, false);
SELECT set_config('t101.rev', platform.fn_staff_invite('rev@x101.test', 'Rev', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x101.test', 'rev@x101.test');
CREATE TEMP TABLE _s AS SELECT s.id, g.code, s.active FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('AE', 'GB') AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
CREATE TEMP TABLE _i AS
  WITH i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container, size_bytes)
             SELECT id, 'T101', current_date - 3, code || '/national_bulletin/T101_x.rar', 'rar', 45000000 FROM _s RETURNING id, source_id)
  SELECT i.id, s.code FROM i JOIN _s s ON s.id = i.source_id;
GRANT SELECT ON _i TO PUBLIC;
INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T101-waiting', current_date - 2, '_mail/abc.pdf', 'pdf' FROM _s WHERE code = 'AE';

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t101.rev'), true);
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM watch.fn_issue_hide((SELECT id FROM _i WHERE code = 'AE'), true); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'only the lead leaves an issue out';
END $$;
SELECT set_config('meesam.user_id', current_setting('t101.lead'), true);
DO $$ BEGIN PERFORM watch.fn_source_show((SELECT id FROM _s WHERE code = 'AE'), true, 'Founder ruling 26 Nov 2026'); END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN ASSERT EXISTS (SELECT 1 FROM watch.fn_shared_issues() WHERE issue_no = 'T101'), 'shown at first'; END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN PERFORM watch.fn_issue_hide((SELECT id FROM _i WHERE code = 'AE'), true); END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ DECLARE denied integer := 0; BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_shared_issues() WHERE issue_no = 'T101'), 'left out: not listed';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_shared_issue_file((SELECT id FROM _i WHERE code = 'AE'))), 'and not to be downloaded';
  BEGIN PERFORM watch.fn_issue_hide((SELECT id FROM _i WHERE code = 'AE'), false); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'an account puts nothing back';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN PERFORM watch.fn_issue_hide((SELECT id FROM _i WHERE code = 'AE'), false); END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN ASSERT EXISTS (SELECT 1 FROM watch.fn_shared_issues() WHERE issue_no = 'T101'), 'put back: listed again'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0101 TESTS PASSED
