-- 0089 — The picture of each published mark is cut out of the issue and kept beside it (the UAE first).
--
-- Founder, 24 Nov 2026: marks are to be compared as pictures too; first the picture of each mark is taken out of
-- the bulletin, then the picture service is switched on. This is the first step only: nothing is compared yet.
-- A bulletin made with a word processor holds each mark's picture as an image of its own. Which image of a
-- notice is the mark is told by the source's settings (fetch_spec.read.picture): at least `min` pixels each way,
-- and not one of the office's own images, whose sizes are listed in `not` (the UAE emblem is drawn 292 by 97 on
-- one form and 606 by 200 on the others). Checked on bulletins 353 and 335: every one of 1,469 marks of 353 has
-- exactly such an image; in 335, 1,743 of 1,747.
-- The worker job "watch.mark_pictures" stores the image in the publications bucket and notes its key here.
BEGIN;

CREATE FUNCTION watch.fn_mark_picture_set(p_issue_id uuid, p_mark_id uuid, p_key text, p_width integer, p_height integer) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
  UPDATE watch.published_mark SET extraction = extraction || jsonb_build_object('image_key', p_key, 'image_w', p_width, 'image_h', p_height, 'has_image', true)
   WHERE issue_id = p_issue_id AND id = p_mark_id AND p_key ~ '\.marks/[A-Za-z0-9_.-]+$'
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_mark_picture_set(uuid, uuid, text, integer, integer) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_mark_picture_set(uuid, uuid, text, integer, integer) TO meesam_worker;

UPDATE watch.publication_source s
   SET fetch_spec = jsonb_set(s.fetch_spec, '{read,picture}', '{"min": 24, "not": [[292, 97], [606, 200]]}'::jsonb)
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'AE' AND s.stream = 'national_bulletin' AND s.fetch_spec -> 'read' ->> 'method' = 'labels';

COMMIT;
