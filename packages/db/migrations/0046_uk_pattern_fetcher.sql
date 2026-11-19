-- 0046 — The UK journal by its file address (Founder, 19 Nov 2026): each weekly journal is one PDF at
-- https://www.ipo.gov.uk/t-tmj/tm-journals/<year>-<number>/jnl.pdf (2026-046 is the journal of 13 Nov 2026).
-- The source becomes a "pattern" source: no page is read; the worker asks for the starting issue and afterwards
-- for the number after the newest one held ("not there yet" is the normal answer until Friday).
BEGIN;

UPDATE watch.publication_source ps
   SET fetch_spec = (ps.fetch_spec - 'link_href' - 'take_latest') || jsonb_build_object(
         'fetcher', 'pattern',
         'url', 'https://www.ipo.gov.uk/t-tmj/tm-journals/',
         'pattern', 'https://www.ipo.gov.uk/t-tmj/tm-journals/{issue}/jnl.pdf',
         'start_issue', '2026-046',
         'observed', '19 Nov 2026: one PDF per weekly journal at a numbered address (year-number); the listing pages answer 403 to the fetcher'),
       failures = 0, next_poll_at = now(), updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'GB' AND ps.stream = 'national_bulletin';

COMMIT;
