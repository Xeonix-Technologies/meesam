-- 0053 — Egypt's trademark gazette linked (Founder, 20 Nov 2026, pages supplied by the Founder).
-- The gazette ("جريدة العلامات التجارية") is on the Egyptian Patent Office's site: an index page
-- (https://www.egypo.gov.eg/page.aspx?id=99) leads to one page per year; 2026 is page.aspx?id=100
-- (2025 was id=75). The page could not be read from outside Egypt when this was written, so its layout is NOT
-- yet known: this row is a first test with the plainest reading — every PDF linked on the 2026 page is taken to
-- be an issue, named by its file name, and only the first one listed is held. It stays OFF until the watch
-- operations lead confirms re-use in the console. To finish it: the page's layout (order, numbers, dates), and
-- the new year's page each January.
BEGIN;

UPDATE watch.publication_source ps
   SET format = 'pdf',
       fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.egypo.gov.eg/page.aspx?id=100',
         'manual_page', 'https://www.egypo.gov.eg/page.aspx?id=99',
         'fetcher', 'page_crawler',
         'link_href', '\.pdf($|\?)',
         'container', 'pdf',
         'take_latest', 1,
         'max_per_run', 1,
         'poll_minutes', 360,
         'max_bytes', 1610612736,
         'reuse', 'To confirm. The site''s terms could not be read (20 Nov 2026).',
         'observed', '20 Nov 2026: trademark gazette by year on egypo.gov.eg (2026 = page id 100); layout not yet seen; first test takes the first PDF listed')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'EG' AND ps.stream = 'national_bulletin';

COMMIT;
