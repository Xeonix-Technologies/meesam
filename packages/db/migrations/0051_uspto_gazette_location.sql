-- 0051 — The USPTO weekly gazette gets its location (Founder, 20 Nov 2026: "activate all registries to test if
-- they work"). Observed 20 Nov 2026 on the Trademark Official Gazette page: one row per week, newest first,
-- "Week #46 - 17 November 2026" followed by the gazette PDF at
-- https://www.uspto.gov/web/trademarks/tmog/20261117_OG.pdf (514.6 MB; earlier weeks 494 to 511 MB).
-- The US source was already switched on at seeding (US government works); with a location it starts by itself.
-- The US opposition period is unverified, so only the newest gazette is held and no deadline is shown.
-- The file is streamed to scratch space and on to the bucket, never held in memory.
BEGIN;

UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.uspto.gov/learning-and-resources/official-gazette/trademark-official-gazette-tmog',
         'manual_page', 'https://www.uspto.gov/learning-and-resources/official-gazette/trademark-official-gazette-tmog',
         'fetcher', 'page_crawler',
         'link_href', '/tmog/\d{8}_OG\.pdf($|\?)',
         'issue_no', '(\d{8})_OG',
         'date', '(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})',
         'date_order', 'dmy',
         'context', 'before',
         'container', 'pdf',
         'take_latest', 1,
         'max_per_run', 1,
         'poll_minutes', 360,
         'max_bytes', 1610612736,
         'observed', '20 Nov 2026: weekly gazette each Tuesday, one PDF of about 500 MB, listed newest first on the TMOG page; daily XML files (TDXF) are documented on data.uspto.gov and not yet profiled'),
       failures = 0, next_poll_at = now(), updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'US';

COMMIT;
