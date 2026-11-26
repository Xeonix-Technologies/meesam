-- 0095 — A picture's usual level against an issue, for the "stands out" measure.
--
-- Found 26 Nov 2026: a lettered mark comes near hundreds of pictures of a bulletin at figures where a picture-only
-- mark comes near none, so one fixed line cannot serve every mark. Each mark has its own usual level against a
-- bulletin; what tells a look-alike is how far one picture stands above that level. This function gives, for a
-- picture staff give on the Pictures page and for each model, the average closeness to the pictures of the issue
-- and its spread (standard deviation), counted as 0094 counts: the same picture printed for several classes once,
-- vectors of another engine left out. Reading only; staff of the console only. Needs pgvector.
BEGIN;

CREATE FUNCTION watch.fn_issue_picture_probe_level(p_issue_id uuid, p_siglip text, p_siglip_engine text, p_dino text, p_dino_engine text)
RETURNS TABLE (model text, pictures integer, level double precision, spread double precision)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = watch, public, pg_temp AS $$
  WITH c AS (
    SELECT DISTINCT ON (COALESCE(m.extraction ->> 'image_phash', m.id::text))
           CASE WHEN p_siglip IS NOT NULL AND m.siglip_embedding IS NOT NULL AND m.extraction ->> 'siglip_engine' = p_siglip_engine
                THEN (1 - (m.siglip_embedding <=> p_siglip::vector(768))) * 100 END AS s,
           CASE WHEN p_dino IS NOT NULL AND m.dino_embedding IS NOT NULL AND m.extraction ->> 'dino_engine' = p_dino_engine
                THEN (1 - (m.dino_embedding <=> p_dino::vector(768))) * 100 END AS d
      FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.extraction ? 'image_key'
     ORDER BY COALESCE(m.extraction ->> 'image_phash', m.id::text), m.id)
  SELECT 'siglip2'::text, count(c.s)::int, round(avg(c.s)::numeric, 2)::double precision, round(COALESCE(stddev_pop(c.s), 0)::numeric, 2)::double precision FROM c HAVING count(c.s) > 0
  UNION ALL
  SELECT 'dinov3'::text, count(c.d)::int, round(avg(c.d)::numeric, 2)::double precision, round(COALESCE(stddev_pop(c.d), 0)::numeric, 2)::double precision FROM c HAVING count(c.d) > 0
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_picture_probe_level(uuid, text, text, text, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_picture_probe_level(uuid, text, text, text, text) TO meesam_staff, meesam_admin;

COMMIT;
