-- 0044 — Bahrain as a small test source for the fetcher (Founder, 19 Nov 2026: "do the same with the rest of the
-- countries"). Observed 19 Nov 2026: the Ministry of Industry and Commerce lists its "Bulletin on Trademarks"
-- issues on one page, highest number first, each a PDF of 1 to 2 MB titled "Issue No. N for the year YYYY
-- regarding trademarks"; the page shows no dates. The fetcher stays OFF until the watch operations lead confirms
-- re-use in the console (the re-use gate is ruled); no terms of re-use were found. The opposition period is
-- unverified, so only the first issue listed is held and no deadline is shown.
-- The US row gets what was observed about the weekly gazette as notes only (no location: its files are 228 to
-- 597 MB each and the Founder asked to start with smaller publications).
BEGIN;

UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.moic.gov.bh/en/node/2817',
         'fetcher', 'page_crawler',
         'link_href', 'regarding\s+trademarks[^/]*\.pdf($|\?)',
         'issue_no', 'Issue\s+No\.?\s*(\d+\s+for\s+the\s+year\s+\d{4})',
         'container', 'pdf',
         'take_latest', 1,
         'max_per_run', 1,
         'poll_minutes', 180,
         'max_bytes', 104857600,
         'reuse', 'To confirm. No terms of re-use were found on the ministry''s page (19 Nov 2026).',
         'observed', '19 Nov 2026: Bulletin on Trademarks page, PDFs of 1 to 2 MB, no dates on the page; the page states objections within sixty days from publication (unverified)')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'BH' AND ps.stream = 'national_bulletin';

UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object(
         'observed', '19 Nov 2026: weekly gazette each Tuesday as one PDF of 228 to 597 MB at https://www.uspto.gov/web/trademarks/tmog/YYYYMMDD_OG.pdf; daily XML files (TDXF) are documented on data.uspto.gov. No location is set until the smaller daily data is profiled.')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'US';

COMMIT;
