-- Tests for migration 0050: a later success, or collection by hand, closes a source's open incident.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t50.lead', platform.fn_staff_invite('lead@x50.test', 'Lead', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'lead@x50.test';
CREATE TEMP TABLE _s AS SELECT s.id, g.code FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('AE', 'GB') AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
UPDATE watch.publication_source SET active = true WHERE id IN (SELECT id FROM _s);
SET LOCAL ROLE meesam_worker;
DO $$
DECLARE ae uuid := (SELECT id FROM _s WHERE code = 'AE'); gb uuid := (SELECT id FROM _s WHERE code = 'GB');
BEGIN
  FOR i IN 1..3 LOOP PERFORM watch.fn_fetch_failed(ae, NULL, NULL, 'u', 'discover', 'timeout'); PERFORM watch.fn_fetch_failed(gb, NULL, NULL, 'u', 'discover', '403'); END LOOP;
  ASSERT (SELECT count(*) FROM watch.fetch_incident WHERE closed_at IS NULL AND source_id IN (ae, gb)) = 2, 'two open incidents';
  PERFORM watch.fn_fetch_stored(ae, '360', current_date, 'u', 't', 'AE/national_bulletin/360_aa.rar', sha256('f360'), 1000, 'rar');
  ASSERT (SELECT closed_at IS NOT NULL AND closed_by IS NULL AND close_note LIKE 'Closed automatically%' FROM watch.fetch_incident WHERE source_id = ae), 'a fetched issue closes the incident, by nobody, with a note';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t50.lead'), true);
DO $$ DECLARE gb uuid := (SELECT id FROM _s WHERE code = 'GB'); BEGIN
  PERFORM watch.fn_source_manual(gb, true, 'the site refuses the fetcher');
  ASSERT (SELECT closed_at IS NOT NULL AND closed_by = current_setting('t50.lead')::uuid AND close_note LIKE '%collected by hand%' FROM watch.fetch_incident WHERE source_id = gb), 'handing the source to collection by hand closes its incident, to the person';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0050 TESTS PASSED
