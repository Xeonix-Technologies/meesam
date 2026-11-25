-- 0092 — Look-alikes: the marks of an issue whose pictures stand nearest to one mark's picture, for staff.
--
-- Founder, 25 Nov 2026: before ruling how a picture score becomes a band, the scores are to be seen on real
-- marks. This function serves the Operations Console page "Pictures": for one mark, the first `n` marks of the
-- same issue by each model's closeness, each with both models' figures (0 to 100: one hundred times the cosine
-- of the two vectors) and its place with each model. A notice that carries the very same picture (the same mark
-- in another class; equal picture hash) is left out. Vectors of different engines are never compared.
-- Reading only: nothing is stored, matched or alerted. Staff of the console only. Needs pgvector.
BEGIN;

CREATE FUNCTION watch.fn_mark_lookalikes(p_issue_id uuid, p_mark_id uuid, p_n integer DEFAULT 10)
RETURNS TABLE (id uuid, application_no text, mark_ar text, mark_en text, classes smallint[], applicant_name text,
               siglip double precision, dino double precision, rank_siglip integer, rank_dino integer)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = watch, public, pg_temp AS $$
  WITH q AS (
    SELECT m.siglip_embedding AS s, m.dino_embedding AS d, m.extraction ->> 'image_phash' AS h,
           m.extraction ->> 'siglip_engine' AS se, m.extraction ->> 'dino_engine' AS de
      FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.id = p_mark_id),
  c AS (
    SELECT m.id, m.application_no, m.mark_text ->> 'ar' AS mark_ar, m.mark_text ->> 'en' AS mark_en, m.classes, m.applicant_name,
           CASE WHEN m.siglip_embedding IS NOT NULL AND q.s IS NOT NULL AND m.extraction ->> 'siglip_engine' IS NOT DISTINCT FROM q.se
                THEN (1 - (m.siglip_embedding <=> q.s)) * 100 END AS siglip,
           CASE WHEN m.dino_embedding IS NOT NULL AND q.d IS NOT NULL AND m.extraction ->> 'dino_engine' IS NOT DISTINCT FROM q.de
                THEN (1 - (m.dino_embedding <=> q.d)) * 100 END AS dino
      FROM watch.published_mark m, q
     WHERE m.issue_id = p_issue_id AND m.id <> p_mark_id AND m.extraction ? 'image_key'
       AND (q.h IS NULL OR m.extraction ->> 'image_phash' IS DISTINCT FROM q.h)),
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
REVOKE EXECUTE ON FUNCTION watch.fn_mark_lookalikes(uuid, uuid, integer) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_mark_lookalikes(uuid, uuid, integer) TO meesam_staff, meesam_admin;

COMMIT;
