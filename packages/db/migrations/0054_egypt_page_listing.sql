-- 0054 — Egypt: read the page first, take nothing (staging, 20 Nov 2026). The first test took the first PDF linked
-- on the 2026 gazette page, which was not a gazette (a WIPO document in the page's furniture, answered 404). The
-- page cannot be read from outside Egypt, but the worker reaches it. So the row is switched to "list_only": the
-- worker reads the page and shows the staff every file it links to, with the words around each link; nothing is
-- downloaded. The row is finished from that list. The wrong candidate recorded by the first test is removed
-- (its attempts stay in the log).
BEGIN;

UPDATE watch.fetch_run r SET issue_id = NULL
  FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id
 WHERE r.issue_id = i.id AND g.code = 'EG' AND i.object_key IS NULL;
DELETE FROM watch.publication_issue i USING watch.publication_source s, registry.registry g
 WHERE s.id = i.source_id AND g.id = s.registry_id AND g.code = 'EG' AND i.object_key IS NULL;

UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object('list_only', true, 'link_href', '\.(pdf|zip|rar)($|\?)'),
       failures = 0, next_poll_at = now(), updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'EG' AND ps.stream = 'national_bulletin';

COMMIT;
