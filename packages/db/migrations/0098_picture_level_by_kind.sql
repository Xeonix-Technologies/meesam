-- 0098 — A picture's usual level against the marks of its own kind.
--
-- Measured 26 Nov 2026: a lettered mark's figures against a whole bulletin scatter so widely (the bulletin mixes
-- lettered and picture-only marks) that even an identical picture stands out by little. This function gives the
-- level and spread of 0095 over the marks of the kinds named only (0097), so a lettered mark is measured against
-- lettered marks. For trying on the Pictures page; reading only; staff of the console only. Needs pgvector.
BEGIN;

CREATE FUNCTION watch.fn_issue_picture_probe_level_kind(p_issue_id uuid, p_siglip text, p_siglip_engine text, p_dino text, p_dino_engine text, p_kinds text[])
RETURNS TABLE (model text, pictures integer, level double precision, spread double precision)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = watch, public, pg_temp AS $$
  WITH c AS (
    SELECT DISTINCT ON (COALESCE(m.extraction ->> 'image_phash', m.id::text))
           CASE WHEN p_siglip IS NOT NULL AND m.siglip_embedding IS NOT NULL AND m.extraction ->> 'siglip_engine' = p_siglip_engine
                THEN (1 - (m.siglip_embedding <=> p_siglip::vector(768))) * 100 END AS s,
           CASE WHEN p_dino IS NOT NULL AND m.dino_embedding IS NOT NULL AND m.extraction ->> 'dino_engine' = p_dino_engine
                THEN (1 - (m.dino_embedding <=> p_dino::vector(768))) * 100 END AS d
      FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.extraction ? 'image_key' AND m.mark_kind = ANY(p_kinds)
     ORDER BY COALESCE(m.extraction ->> 'image_phash', m.id::text), m.id)
  SELECT 'siglip2'::text, count(c.s)::int, round(avg(c.s)::numeric, 2)::double precision, round(COALESCE(stddev_pop(c.s), 0)::numeric, 2)::double precision FROM c HAVING count(c.s) > 0
  UNION ALL
  SELECT 'dinov3'::text, count(c.d)::int, round(avg(c.d)::numeric, 2)::double precision, round(COALESCE(stddev_pop(c.d), 0)::numeric, 2)::double precision FROM c HAVING count(c.d) > 0
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_picture_probe_level_kind(uuid, text, text, text, text, text[]) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_picture_probe_level_kind(uuid, text, text, text, text, text[]) TO meesam_staff, meesam_admin;

COMMIT;
