-- Tests for migration 0048: an issue added by hand joins the fetcher's failed attempt whatever separator is typed.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t48.lead', platform.fn_staff_invite('lead@x48.test', 'Lead', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'lead@x48.test';
CREATE TEMP TABLE _s AS SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'GB' AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;
UPDATE watch.publication_source SET active = true WHERE id = (SELECT id FROM _s);
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN PERFORM watch.fn_fetch_failed((SELECT id FROM _s), '2026-046', NULL, 'https://x/2026-046/jnl.pdf', 'download', 'answered 403'); END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t48.lead'), true);
DO $$
DECLARE gb uuid := (SELECT id FROM _s); v uuid; refused boolean := false;
BEGIN
  PERFORM watch.fn_source_manual(gb, true, 'site refuses the fetcher');
  v := watch.fn_manual_add(gb, '2026/046', current_date - 6, 'GB/national_bulletin/2026-046_aa.pdf', sha256('j46'), 16000000, 'pdf', 'jnl.pdf');
  ASSERT (SELECT count(*) FROM watch.publication_issue WHERE source_id = gb) = 1, 'one issue, not two';
  ASSERT (SELECT issue_no = '2026-046' AND object_key IS NOT NULL AND intake = 'manual' AND source_url IS NOT NULL FROM watch.publication_issue WHERE id = v), 'it keeps the number on record and the file is held';
  BEGIN PERFORM watch.fn_manual_add(gb, '2026 046', current_date - 6, 'k', sha256('other'), 10, 'pdf', 'x.pdf'); EXCEPTION WHEN unique_violation THEN refused := true; END;
  ASSERT refused, 'the same issue typed a third way is still the same issue';
  v := watch.fn_manual_add(gb, '2026/047', current_date, 'GB/national_bulletin/2026-047_bb.pdf', sha256('j47'), 16000000, 'pdf', 'jnl.pdf');
  ASSERT (SELECT issue_no FROM watch.publication_issue WHERE id = v) = '2026-047', 'a new number is written with hyphens';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN ASSERT (SELECT stored FROM watch.fn_fetch_known((SELECT id FROM _s)) WHERE issue_no = '2026-047'), 'so the fetcher, once allowed, sees it as held'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0048 TESTS PASSED
