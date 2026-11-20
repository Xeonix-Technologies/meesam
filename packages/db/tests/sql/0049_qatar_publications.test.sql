-- Tests for migration 0049: Qatar's two publications are in the catalogue, off until re-use is confirmed.
BEGIN;
SET client_min_messages = warning;
DO $$
DECLARE n record;
BEGIN
  ASSERT (SELECT count(*) FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND NOT s.active AND s.fetch_spec ? 'url') = 2, 'national and Madrid, both with a location, both off';
  SELECT * INTO n FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin';
  ASSERT n.fetch_spec ->> 'date_order' = 'mdy' AND n.fetch_spec ->> 'context' = 'before' AND NOT (n.fetch_spec ? 'take_latest'), 'the national gazette is read by its heading; its window decides what is taken';
  ASSERT (SELECT days FROM watch.fn_source_window(n.id)) = 60, 'Qatar''s opposition period is verified in its profile';
  ASSERT watch.fn_fetch_wanted(n.id, current_date - 40) AND NOT watch.fn_fetch_wanted(n.id, current_date - 70), 'an issue is taken while its sixty days run';
  ASSERT (SELECT count(*) FROM watch.publication_schedule c JOIN watch.publication_source s ON s.id = c.source_id JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND c.frequency = 'monthly') = 2, 'about monthly';
END $$;
DO $$ BEGIN
  ASSERT (SELECT NOT active AND fetch_spec ->> 'url' LIKE '%egypo.gov.eg/page.aspx?id=100' AND NOT (fetch_spec ? 'list_only') AND fetch_spec ->> 'context' = 'row' AND fetch_spec ->> 'order' = 'oldest_first' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'EG'), 'Egypt (0053 to 0056): the 2026 gazette table, read by row, newest taken, off';
  ASSERT (SELECT NOT active AND jsonb_array_length(fetch_spec -> 'month_names') = 12 AND fetch_spec ->> 'issue_no' LIKE 'Marka%' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR'), 'Türkiye (0052): location set, Turkish month names as data, trademark entries only, off';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_fetch_due() WHERE registry_code = 'QA'), 'off means not polled'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0049 TESTS PASSED
