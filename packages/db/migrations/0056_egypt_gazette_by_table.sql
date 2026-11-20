-- 0056 — Egypt's gazette read from its table (Founder's screenshot of the 2026 page, 20 Nov 2026).
-- The page shows one table, "جريدة العلامات التجارية 2026": a row per monthly issue, oldest first, with the issue
-- number as the link (1025 … 1035), the month's name, and a date written year-month-day (2026-1-6 … 2026-11-19).
-- The links are not addresses ending in a file type, so an issue link is told by its text (a number) and the
-- number and date are read from the link's own table row. The page lists oldest first; the newest is taken.
-- Listing mode is switched off. What the links return is not yet known: the file is kept only if it is a PDF
-- (the shape check refuses anything else, and the attempt then shows the link's address).
BEGIN;

UPDATE watch.publication_source ps
   SET cadence = 'monthly (observed: issues 1025 to 1035, Jan to Nov 2026)',
       fetch_spec = (ps.fetch_spec - 'list_only' - 'list_limit') || jsonb_build_object(
         'link_href', '.',
         'link_text', '^\d{3,5}$',
         'issue_no', '(\d{3,5})',
         'date', '(\d{4})-(\d{1,2})-(\d{1,2})',
         'date_order', 'ymd',
         'context', 'row',
         'order', 'oldest_first',
         'container', 'pdf',
         'take_latest', 1,
         'max_per_run', 1,
         'observed', '20 Nov 2026: one table per year on egypo.gov.eg (2026 = page id 100), a row per monthly issue, oldest first; issue 1035 is dated 2026-11-19'),
       failures = 0, next_poll_at = now(), updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'EG' AND ps.stream = 'national_bulletin';

INSERT INTO watch.publication_schedule (source_id, frequency, timezone)
SELECT ps.id, 'monthly', 'Africa/Cairo'
  FROM watch.publication_source ps JOIN registry.registry g ON g.id = ps.registry_id
 WHERE g.code = 'EG' AND ps.stream = 'national_bulletin'
ON CONFLICT (source_id) DO NOTHING;

COMMIT;
