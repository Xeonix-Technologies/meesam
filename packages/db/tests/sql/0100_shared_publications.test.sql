-- Tests for migration 0100: an account sees the issues of a source only once the lead has switched it on.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t100.lead', platform.fn_staff_invite('lead@x100.test', 'Lead Person', 'watch_lead')::text, false);
SELECT set_config('t100.rev', platform.fn_staff_invite('rev@x100.test', 'Rev', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x100.test', 'rev@x100.test');
CREATE TEMP TABLE _s AS SELECT s.id, g.code, s.active FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('AE', 'GB') AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
CREATE TEMP TABLE _i AS
  WITH i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container, size_bytes)
             SELECT id, 'T100', current_date - 3, code || '/national_bulletin/T100_x.rar', 'rar', 45000000 FROM _s RETURNING id, source_id)
  SELECT i.id, s.code FROM i JOIN _s s ON s.id = i.source_id;
GRANT SELECT ON _i TO PUBLIC;
INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T100-waiting', current_date - 2, '_mail/abc.pdf', 'pdf' FROM _s WHERE code = 'AE';

SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_shared_issues() WHERE issue_no LIKE 'T100%'), 'nothing is shown before a source is switched on';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_shared_issue_file((SELECT id FROM _i WHERE code = 'AE'))), 'and nothing can be downloaded';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t100.rev'), true);
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM watch.fn_source_show((SELECT id FROM _s WHERE code = 'AE'), true, 'x'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'only the lead switches it';
END $$;
SELECT set_config('meesam.user_id', current_setting('t100.lead'), true);
DO $$ DECLARE refused integer := 0; ae uuid := (SELECT id FROM _s WHERE code = 'AE'); gb uuid := (SELECT id FROM _s WHERE code = 'GB' AND NOT active); BEGIN
  BEGIN PERFORM watch.fn_source_show(ae, true, ' '); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 1, 'a basis is required';
  IF gb IS NOT NULL THEN
    BEGIN PERFORM watch.fn_source_show(gb, true, 'agreed'); EXCEPTION WHEN no_data_found THEN refused := refused + 1; END;
    ASSERT refused = 2, 'a source whose re-use is not confirmed cannot be shown';
  END IF;
  PERFORM watch.fn_source_show(ae, true, 'Founder ruling 26 Nov 2026');
  ASSERT (SELECT shown_to_accounts AND shown_basis = 'Founder ruling 26 Nov 2026' AND shown_by = current_setting('t100.lead')::uuid FROM watch.publication_source WHERE id = ae), 'switched on, with the basis and who';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ DECLARE r record; denied integer := 0; BEGIN
  SELECT * INTO r FROM watch.fn_shared_issues() WHERE issue_no = 'T100';
  ASSERT r.registry_code = 'AE' AND r.container = 'rar' AND r.size_bytes = 45000000 AND r.marks = 0, 'the UAE issue is shown, and only it';
  ASSERT (SELECT count(*) FROM watch.fn_shared_issues() WHERE issue_no LIKE 'T100%') = 1, 'not the other registry''s issue, and never a file still waiting from the mailbox';
  ASSERT (SELECT object_key FROM watch.fn_shared_issue_file((SELECT id FROM _i WHERE code = 'AE'))) = 'AE/national_bulletin/T100_x.rar', 'its file can be fetched';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_shared_issue_file((SELECT id FROM _i WHERE code = 'GB'))), 'the other registry''s file cannot';
  BEGIN PERFORM watch.fn_source_show((SELECT id FROM _s WHERE code = 'AE'), false); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'an account switches nothing';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t100.lead'), true);
DO $$ BEGIN PERFORM watch.fn_source_show((SELECT id FROM _s WHERE code = 'AE'), false); END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_shared_issues() WHERE issue_no = 'T100'), 'switched off: gone again'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0100 TESTS PASSED
