-- 0088 — The UAE settings after a look at an older issue (bulletin 335, early 2026), the same day as 0087.
--
-- Found: (a) the Madrid form then opened with "The Trademarks and Intellectual Works Department" (today "The
-- Trademarks Department"), so the file was not told and would have been left unread; (b) an issue can carry a
-- part that 353 does not have: cancellations ("نموذج إعلان النشر عن الشطب"), on the same form as the changes.
-- The accepted marks (2,104 pages, 1,747 marks, one incomplete) and the registrations read as they are.
-- Settings only; nothing else changes. A part whose title no form knows is still left unread and named in the log.
BEGIN;

UPDATE watch.publication_source s
   SET fetch_spec = jsonb_set(s.fetch_spec, '{read,forms}', (
         SELECT jsonb_agg(CASE
                  WHEN f ->> 'key' = 'madrid' THEN f || '{"title": "^TheTrademarks[A-Za-z]{0,40}Department", "start": "The Trademarks"}'::jsonb
                  WHEN f ->> 'key' = 'change_of_mark' THEN jsonb_set(f, '{labels}', (f -> 'labels') || $l$[
                         {"label": "بطلب شطب تسجيل بيانات العلامة التجارية :", "field": "mark"},
                         {"label": "وقد تقرر شطب العلامة بتاريخ :", "field": "changed_on"},
                         {"label": "أسباب الشطب :", "field": "change"}]$l$::jsonb)
                  ELSE f END ORDER BY ord)
                || $c$[{"key": "cancellation", "like": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنالشطب", "layout": "columns"}]$c$::jsonb
           FROM jsonb_array_elements(s.fetch_spec -> 'read' -> 'forms') WITH ORDINALITY AS x(f, ord)))
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'AE' AND s.stream = 'national_bulletin' AND s.fetch_spec -> 'read' ->> 'method' = 'labels'
   AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s.fetch_spec -> 'read' -> 'forms') f WHERE f ->> 'key' = 'cancellation');

COMMIT;
