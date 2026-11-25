-- 0093 — The spread of nearest-picture figures in an issue, for ruling where the picture bands go.
--
-- Founder, 25 Nov 2026: a first real case was tried (a Saudi device mark and a later mark using a like frame);
-- the Founder would want an alert at about that closeness, and the lines are to be improved over time. To rule a
-- line one must know how many marks of an ordinary bulletin already have a neighbour above it. This function
-- answers that for one issue: for each mark with a picture, the closeness of its nearest other picture (the
-- very same picture and vectors of another engine left out), counted in steps of ten for each model.
-- For a large issue 1,500 marks are taken as the ones asked about, always the same ones, each still compared
-- with every mark of the issue. Reading only; staff of the console only. Needs pgvector.
BEGIN;

CREATE FUNCTION watch.fn_issue_picture_spread(p_issue_id uuid)
RETURNS TABLE (model text, step integer, marks integer)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = watch, public, pg_temp AS $$
  WITH m AS (
    SELECT x.id, x.siglip_embedding AS s, x.dino_embedding AS d, x.extraction ->> 'image_phash' AS h,
           x.extraction ->> 'siglip_engine' AS se, x.extraction ->> 'dino_engine' AS de
      FROM watch.published_mark x WHERE x.issue_id = p_issue_id AND x.extraction ? 'image_key'),
  q AS (SELECT * FROM m ORDER BY md5(m.id::text) LIMIT 1500),
  b AS (
    SELECT q.id,
           max(CASE WHEN q.s IS NOT NULL AND o.s IS NOT NULL AND q.se IS NOT DISTINCT FROM o.se THEN 1 - (q.s <=> o.s) END) * 100 AS s,
           max(CASE WHEN q.d IS NOT NULL AND o.d IS NOT NULL AND q.de IS NOT DISTINCT FROM o.de THEN 1 - (q.d <=> o.d) END) * 100 AS d
      FROM q JOIN m o ON o.id <> q.id AND (q.h IS NULL OR o.h IS DISTINCT FROM q.h)
     GROUP BY q.id)
  SELECT 'siglip2'::text, greatest(-10, least(90, (floor(b.s / 10) * 10)::int)), count(*)::int FROM b WHERE b.s IS NOT NULL GROUP BY 2
  UNION ALL
  SELECT 'dinov3'::text, greatest(-10, least(90, (floor(b.d / 10) * 10)::int)), count(*)::int FROM b WHERE b.d IS NOT NULL GROUP BY 2
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_picture_spread(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_picture_spread(uuid) TO meesam_staff, meesam_admin;

COMMIT;
