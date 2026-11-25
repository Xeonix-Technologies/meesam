-- 0094 — One picture against a whole issue: the question the watch will really ask.
--
-- Found 25 Nov 2026 on bulletin 354: inside one bulletin nearly every mark has a very near neighbour (by DINOv3,
-- 94 of 100 marks have another picture at 50 or nearer; by SigLIP 2, 99 of 100 at 60 or nearer), because most
-- pictures are plain words on white, which the models see as alike, and because one applicant often files several
-- forms of one mark. So a line cannot be read off pairs inside a bulletin. What the watch compares is one mark of
-- a customer with every picture of a bulletin; these two functions answer that for a picture staff give on the
-- Pictures page: the nearest marks by each model, and how many marks stand at each step of closeness.
-- The picture's two vectors come from the picture service with their engines' names; a mark whose vector was
-- made by another engine is not compared, and the very same picture carried by several notices (one mark in
-- several classes) is counted once. Reading only; staff of the console only. Needs pgvector.
BEGIN;

CREATE FUNCTION watch.fn_issue_picture_probe(p_issue_id uuid, p_siglip text, p_siglip_engine text, p_dino text, p_dino_engine text, p_n integer DEFAULT 10)
RETURNS TABLE (id uuid, application_no text, mark_ar text, mark_en text, classes smallint[], applicant_name text,
               siglip double precision, dino double precision, rank_siglip integer, rank_dino integer)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = watch, public, pg_temp AS $$
  WITH c AS (
    SELECT DISTINCT ON (COALESCE(m.extraction ->> 'image_phash', m.id::text)) m.id, m.application_no, m.mark_text ->> 'ar' AS mark_ar, m.mark_text ->> 'en' AS mark_en, m.classes, m.applicant_name,
           CASE WHEN p_siglip IS NOT NULL AND m.siglip_embedding IS NOT NULL AND m.extraction ->> 'siglip_engine' = p_siglip_engine
                THEN (1 - (m.siglip_embedding <=> p_siglip::vector(768))) * 100 END AS siglip,
           CASE WHEN p_dino IS NOT NULL AND m.dino_embedding IS NOT NULL AND m.extraction ->> 'dino_engine' = p_dino_engine
                THEN (1 - (m.dino_embedding <=> p_dino::vector(768))) * 100 END AS dino
      FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.extraction ? 'image_key'
     ORDER BY COALESCE(m.extraction ->> 'image_phash', m.id::text), m.id),
  r AS (
    SELECT c.*, CASE WHEN c.siglip IS NOT NULL THEN row_number() OVER (ORDER BY c.siglip DESC NULLS LAST, c.id) END AS rs,
                CASE WHEN c.dino IS NOT NULL THEN row_number() OVER (ORDER BY c.dino DESC NULLS LAST, c.id) END AS rd
      FROM c)
  SELECT r.id, r.application_no, r.mark_ar, r.mark_en, r.classes, r.applicant_name,
         round(r.siglip::numeric, 1)::double precision, round(r.dino::numeric, 1)::double precision, r.rs::integer, r.rd::integer
    FROM r
   WHERE r.rs <= least(50, greatest(1, COALESCE(p_n, 10))) OR r.rd <= least(50, greatest(1, COALESCE(p_n, 10)))
   ORDER BY LEAST(COALESCE(r.rs, 9999), COALESCE(r.rd, 9999)), r.id
$$;

CREATE FUNCTION watch.fn_issue_picture_probe_spread(p_issue_id uuid, p_siglip text, p_siglip_engine text, p_dino text, p_dino_engine text)
RETURNS TABLE (model text, step integer, marks integer)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = watch, public, pg_temp AS $$
  WITH c AS (
    SELECT DISTINCT ON (COALESCE(m.extraction ->> 'image_phash', m.id::text))
           CASE WHEN p_siglip IS NOT NULL AND m.siglip_embedding IS NOT NULL AND m.extraction ->> 'siglip_engine' = p_siglip_engine
                THEN (1 - (m.siglip_embedding <=> p_siglip::vector(768))) * 100 END AS s,
           CASE WHEN p_dino IS NOT NULL AND m.dino_embedding IS NOT NULL AND m.extraction ->> 'dino_engine' = p_dino_engine
                THEN (1 - (m.dino_embedding <=> p_dino::vector(768))) * 100 END AS d
      FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.extraction ? 'image_key'
     ORDER BY COALESCE(m.extraction ->> 'image_phash', m.id::text), m.id)
  SELECT 'siglip2'::text, greatest(-10, least(90, (floor(c.s / 10) * 10)::int)), count(*)::int FROM c WHERE c.s IS NOT NULL GROUP BY 2
  UNION ALL
  SELECT 'dinov3'::text, greatest(-10, least(90, (floor(c.d / 10) * 10)::int)), count(*)::int FROM c WHERE c.d IS NOT NULL GROUP BY 2
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_picture_probe(uuid, text, text, text, text, integer) FROM PUBLIC, meesam_app;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_picture_probe_spread(uuid, text, text, text, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_picture_probe(uuid, text, text, text, text, integer) TO meesam_staff, meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_issue_picture_probe_spread(uuid, text, text, text, text) TO meesam_staff, meesam_admin;

COMMIT;
