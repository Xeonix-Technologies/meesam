-- 0055 — Egypt: list every link on the gazette page, not only file links (staging, 20 Nov 2026). The listing
-- showed a single PDF link on the 2026 page, and it is not a gazette: the monthly gazette entries are therefore
-- not plain PDF/ZIP/RAR links (they may lead to further pages, to a viewer, or be script links). The listing now
-- shows every link, up to 200, so the row can be finished from what the page really contains.
BEGIN;

UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object('list_only', true, 'link_href', '.', 'list_limit', 200),
       failures = 0, next_poll_at = now(), updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'EG' AND ps.stream = 'national_bulletin';

COMMIT;
