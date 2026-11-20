-- 0049 — Qatar's publications linked (Founder, 20 Nov 2026).
-- Observed 20 Nov 2026 on the Ministry of Commerce and Industry's "Reports & Statistics" page
-- (https://www.moci.gov.qa/en/reports-statistics), newest first, each entry a heading followed by a PDF link:
--   * Industrial Property Gazette, in two parts per issue: "Issue No. 352 (A) - October 15, 2026" and "(B)";
--     before it No. 351 (A) and (B) of September 17, 2026 (about monthly);
--   * Madrid Trademark Gazette: "No. MD13 – October 2026" (posted 2026-11-11), MD12 (2026-10-08), MD11.
-- Both are entered in the catalogue. Their fetchers stay OFF until the watch operations lead confirms re-use in
-- the console (the re-use gate is ruled); no terms of re-use were found on the ministry's site.
-- Qatar's opposition period is verified in its profile (60 days), so issues are taken while their window is open.
-- Not known yet: what parts (A) and (B) each contain, and whether the Madrid gazette's posting date is the date
-- its opposition period runs from. RULING NEEDED on both before any Qatar deadline is shown to an account.
BEGIN;

UPDATE watch.publication_source ps
   SET format = 'pdf', cadence = 'about monthly (observed: 17 Sep and 15 Oct 2026)',
       fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.moci.gov.qa/en/reports-statistics',
         'manual_page', 'https://www.moci.gov.qa/en/reports-statistics',
         'fetcher', 'page_crawler',
         'link_href', 'الصحيفة الرسمية[^/]*\.pdf($|\?)',
         'issue_no', 'Issue\s+No\.?\s*(\d+\s*\([A-Z]\))',
         'date', '([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})',
         'date_order', 'mdy',
         'context', 'before',
         'container', 'pdf',
         'max_per_run', 2,
         'poll_minutes', 180,
         'max_bytes', 524288000,
         'reuse', 'To confirm. No terms of re-use were found on the ministry''s site (20 Nov 2026).',
         'observed', '20 Nov 2026: Industrial Property Gazette in parts (A) and (B) per issue, PDF, on the Reports & Statistics page; newest is No. 352 of 15 Oct 2026')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'QA' AND ps.stream = 'national_bulletin';

INSERT INTO watch.publication_source (registry_id, stream, format, cadence, active, fetch_spec)
SELECT g.id, 'madrid_designations', 'pdf', 'about monthly (observed: MD12 posted 8 Oct, MD13 posted 11 Nov 2026)', false,
       jsonb_build_object(
         'where', 'Ministry of Commerce and Industry, Reports & Statistics page',
         'url', 'https://www.moci.gov.qa/en/reports-statistics',
         'manual_page', 'https://www.moci.gov.qa/en/reports-statistics',
         'fetcher', 'page_crawler',
         'link_href', '(MD\s*\d+|مدريد)[^/]*\.pdf($|\?)',
         'issue_no', '(MD\s*\d+)',
         'date', '(\d{4})-(\d{2})-(\d{2})',
         'date_order', 'ymd',
         'context', 'before',
         'container', 'pdf',
         'max_per_run', 2,
         'poll_minutes', 180,
         'max_bytes', 524288000,
         'reuse', 'To confirm. No terms of re-use were found on the ministry''s site (20 Nov 2026).',
         'observed', '20 Nov 2026: Madrid Trademark Gazette, one PDF per number; the date read is the date the page shows beside the entry (its posting date)')
  FROM registry.registry g
 WHERE g.code = 'QA'
   AND NOT EXISTS (SELECT 1 FROM watch.publication_source x WHERE x.registry_id = g.id AND x.stream = 'madrid_designations');

INSERT INTO watch.publication_schedule (source_id, frequency, timezone)
SELECT ps.id, 'monthly', 'Asia/Qatar'
  FROM watch.publication_source ps JOIN registry.registry g ON g.id = ps.registry_id
 WHERE g.code = 'QA'
ON CONFLICT (source_id) DO NOTHING;

COMMIT;
