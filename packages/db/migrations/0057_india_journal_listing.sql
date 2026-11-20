-- 0057 — India's Trade Marks Journal: profile the page first (Founder, 20 Nov 2026).
-- Observed 20 Nov 2026 at https://search.ipindia.gov.in/IPOJournal/Journal/Trademark: weekly journals, newest
-- first (No. 2287 published 16/11/2026, 2286 on 09/11/2026, 2285 on 02/11/2026), each in class parts
-- ("Class 1-9", "Class 10-18", … "Multiclass - Notice") under a "Download" heading. Whether those parts are
-- links with addresses or form buttons could not be told from outside, so the row is entered in listing mode:
-- once switched on, the worker reads the page and shows the staff what it links to; nothing is downloaded.
-- It stays OFF until the watch operations lead confirms re-use in the console. One gentle read every 12 hours.
BEGIN;

UPDATE watch.publication_source ps
   SET format = 'pdf', cadence = 'weekly (observed: 2, 9 and 16 Nov 2026)',
       fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://search.ipindia.gov.in/IPOJournal/Journal/Trademark',
         'manual_page', 'https://search.ipindia.gov.in/IPOJournal/Journal/Trademark',
         'fetcher', 'page_crawler',
         'list_only', true,
         'link_href', '.',
         'list_limit', 120,
         'container', 'pdf',
         'poll_minutes', 720,
         'reuse', 'To confirm. No terms of re-use were found on the page (20 Nov 2026).',
         'observed', '20 Nov 2026: weekly journal No. 2287 of 16/11/2026 in class parts; how the parts are downloaded is not yet seen')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'IN' AND ps.stream = 'national_bulletin';

COMMIT;
