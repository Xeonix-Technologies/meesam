-- Tests for migration 0094: one picture given by staff against every picture of an issue.
BEGIN;
SET client_min_messages = warning;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T94', current_date - 20, 'AE/national_bulletin/T94_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
CREATE FUNCTION pg_temp.v(a float8, b float8) RETURNS text LANGUAGE sql AS
  $$ SELECT '[' || a::text || ',' || b::text || ',' || (SELECT string_agg('0', ',') FROM generate_series(1, 766)) || ']' $$;
GRANT EXECUTE ON FUNCTION pg_temp.v(float8, float8) TO PUBLIC;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, mark_text, extraction)
SELECT issue_id, registry_id, current_date - 20, n, '{9}', jsonb_build_object('en', w), jsonb_build_object('page', p, 'read_by', 'labels', 'image_key', 'AE/national_bulletin/T94_x.marks/accepted-p' || p || '.png')
  FROM _t, (VALUES ('300001', 'NEAR', 1), ('300002', 'MIDDLE', 2), ('300003', 'FAR', 3), ('300004', 'OLD', 4)) v(n, w, p);
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); BEGIN
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '300001'), 'siglip2', pg_temp.v(1, 0), 'S@1', NULL);
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '300002'), 'siglip2', pg_temp.v(0.6, 0.8), 'S@1', NULL);
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '300003'), 'siglip2', pg_temp.v(0, 1), 'S@1', NULL);
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '300004'), 'siglip2', pg_temp.v(1, 0), 'S@OLD', NULL);
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '300003'), 'dinov3', pg_temp.v(1, 0), 'D@1', NULL);
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); r record; BEGIN
  SELECT * INTO r FROM watch.fn_issue_picture_probe(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1', 10) x WHERE x.application_no = '300001';
  ASSERT r.rank_siglip = 1 AND r.siglip > 99.9 AND r.dino IS NULL AND r.mark_en = 'NEAR', 'the nearest by SigLIP comes first';
  SELECT * INTO r FROM watch.fn_issue_picture_probe(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1', 10) x WHERE x.application_no = '300003';
  ASSERT r.rank_siglip = 3 AND r.siglip < 0.1 AND r.rank_dino = 1 AND r.dino > 99.9, 'each model has its own order';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_issue_picture_probe(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1', 10) x WHERE x.application_no = '300004'), 'a vector made by another engine is not compared';
  ASSERT (SELECT count(*) FROM watch.fn_issue_picture_probe(i, pg_temp.v(1, 0), 'S@1', NULL, NULL, 1)) = 1, 'with one model only, its first mark';
  ASSERT (SELECT marks FROM watch.fn_issue_picture_probe_spread(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1') WHERE model = 'siglip2' AND step = 90) = 1
     AND (SELECT marks FROM watch.fn_issue_picture_probe_spread(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1') WHERE model = 'siglip2' AND step = 60) = 1
     AND (SELECT marks FROM watch.fn_issue_picture_probe_spread(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1') WHERE model = 'siglip2' AND step = 0) = 1
     AND (SELECT sum(marks) FROM watch.fn_issue_picture_probe_spread(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1') WHERE model = 'siglip2') = 3, 'the marks are counted by step: one near, one in the sixties, one apart';
  ASSERT (SELECT sum(marks) FROM watch.fn_issue_picture_probe_spread(i, pg_temp.v(1, 0), 'S@1', pg_temp.v(1, 0), 'D@1') WHERE model = 'dinov3') = 1, 'DINOv3 counts only the marks that have its vector';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN PERFORM * FROM watch.fn_issue_picture_probe(gen_random_uuid(), NULL, NULL, NULL, NULL, 10); ASSERT false, 'an account must not probe';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0094 TESTS PASSED
