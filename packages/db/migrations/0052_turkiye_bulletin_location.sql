-- 0052 — Türkiye's trademark bulletin linked (Founder, 20 Nov 2026, page supplied by the Founder).
-- Observed 20 Nov 2026 at https://www.turkpatent.gov.tr/bultenler: the office lists its latest bulletins of every
-- kind (trademark "Marka", design, patent, geographical indication), each with a number ("Sayı 504"), a date in
-- Turkish ("12 Kasım 2026") and two links, view and download, to webim.turkpatent.gov.tr/file/<id>. The trademark
-- bulletins seen: No. 504 (12 Nov 2026), 503 (27 Oct 2026), 502 (12 Oct 2026): about twice a month.
-- Only the "Marka" entries are taken. The fetcher stays OFF until the watch operations lead confirms re-use in
-- the console; no terms were found on the page. Türkiye's opposition period is unverified: the newest bulletin
-- only, and no deadline. (The separate site bulten.turkpatent.gov.tr tells robots to stay out and is not used.)
BEGIN;

UPDATE watch.publication_source ps
   SET format = 'pdf', cadence = 'about twice a month (observed: 12 Oct, 27 Oct, 12 Nov 2026)',
       fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.turkpatent.gov.tr/bultenler',
         'manual_page', 'https://www.turkpatent.gov.tr/bultenler',
         'fetcher', 'page_crawler',
         'link_href', 'webim\.turkpatent\.gov\.tr/file/[0-9a-f-]+\?download',
         'issue_no', 'Marka,?\s*Sayı\s*(\d+)',
         'date', '(\d{1,2})\s+([A-Za-zÇĞİÖŞÜçğıöşü]+)\s+(\d{4})',
         'date_order', 'dmy',
         'month_names', jsonb_build_array('Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'),
         'context', 'before',
         'container', 'pdf',
         'take_latest', 1,
         'max_per_run', 1,
         'poll_minutes', 360,
         'max_bytes', 1610612736,
         'reuse', 'To confirm. No terms of re-use were found on the page (20 Nov 2026).',
         'observed', '20 Nov 2026: bulletins of every kind on one page; trademark bulletin No. 504 of 12 Nov 2026 is the newest; the file kind is assumed to be PDF')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'TR' AND ps.stream = 'national_bulletin';

COMMIT;
