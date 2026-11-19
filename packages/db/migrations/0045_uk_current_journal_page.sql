-- 0045 — The UK source reads the "current journal" page the Founder pointed to (19 Nov 2026) instead of the
-- "previous publications" page, which answered 403 to the fetcher. That page offers the current week's journal
-- as one PDF and shows no number or date, so the file's own name identifies the issue. The failure count
-- starts afresh so the change is tried at the next round; the fetcher keeps identifying itself as Meesam's.
BEGIN;

UPDATE watch.publication_source ps
   SET fetch_spec = (ps.fetch_spec - 'issue_no' - 'date' - 'context') || jsonb_build_object(
         'url', 'https://www.ipo.gov.uk/t-tmj.htm',
         'observed', '19 Nov 2026: current journal page, one PDF of about 13 to 17 MB per week, no number or date on the page'),
       failures = 0, next_poll_at = now(), updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'GB' AND ps.stream = 'national_bulletin';

COMMIT;
