-- Tests for migration 0102: the lead names the relay a source is fetched through, or takes it away.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t102.lead', platform.fn_staff_invite('lead@x102.test', 'Lead Person', 'watch_lead')::text, false);
SELECT set_config('t102.rev', platform.fn_staff_invite('rev@x102.test', 'Rev', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x102.test', 'rev@x102.test');
CREATE TEMP TABLE _s AS SELECT s.id, s.fetch_spec FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t102.rev'), true);
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM watch.fn_source_via((SELECT id FROM _s), 'SA'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'only the lead names a relay';
END $$;
SELECT set_config('meesam.user_id', current_setting('t102.lead'), true);
DO $$ DECLARE refused integer := 0; s uuid := (SELECT id FROM _s); BEGIN
  BEGIN PERFORM watch.fn_source_via(s, 'https://relay.example'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 1, 'a name, never an address';
  PERFORM watch.fn_source_via(s, ' sa ');
  ASSERT (SELECT fetch_spec ->> 'via' = 'SA' AND fetch_spec ->> 'url' = (SELECT fetch_spec ->> 'url' FROM _s) AND fetch_spec -> 'read' = (SELECT fetch_spec -> 'read' FROM _s) FROM watch.publication_source WHERE id = s), 'the name is kept in capitals; nothing else of the source changes';
  PERFORM watch.fn_source_via(s, '');
  ASSERT (SELECT NOT (fetch_spec ? 'via') FROM watch.publication_source WHERE id = s), 'taken away: fetched directly again';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM watch.fn_source_via((SELECT id FROM _s), 'SA'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'an account names nothing';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0102 TESTS PASSED
