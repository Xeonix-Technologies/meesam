-- Tests for migration 0093: how near each mark's nearest other picture is, counted in steps of ten for each model.
BEGIN;
SET client_min_messages = warning;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T93', current_date - 20, 'AE/national_bulletin/T93_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
CREATE FUNCTION pg_temp.v(a float8, b float8) RETURNS text LANGUAGE sql AS
  $$ SELECT '[' || a::text || ',' || b::text || ',' || (SELECT string_agg('0', ',') FROM generate_series(1, 766)) || ']' $$;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, extraction)
SELECT issue_id, registry_id, current_date - 20, n, '{9}', jsonb_build_object('page', p, 'read_by', 'labels', 'image_key', 'AE/national_bulletin/T93_x.marks/accepted-p' || p || '.png')
  FROM _t, (VALUES ('200001', 1), ('200002', 2), ('200003', 3), ('200004', 4)) v(n, p);
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); BEGIN
  -- 200001 and 200002 carry the very same picture; 200003 stands near them (cosine about 0.99); 200004 stands apart (cosine 0 to the first two)
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '200001'), 'siglip2', pg_temp.v(1, 0), 'S@1', 'aaaaaaaaaaaaaaaa');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '200002'), 'siglip2', pg_temp.v(1, 0), 'S@1', 'aaaaaaaaaaaaaaaa');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '200003'), 'siglip2', pg_temp.v(0.9, 0.1), 'S@1', 'bbbbbbbbbbbbbbbb');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '200004'), 'siglip2', pg_temp.v(0, 1), 'S@1', 'cccccccccccccccc');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '200001'), 'dinov3', pg_temp.v(1, 0), 'D@1', 'aaaaaaaaaaaaaaaa');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '200004'), 'dinov3', pg_temp.v(0.6, 0.8), 'D@1', 'cccccccccccccccc');
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); BEGIN
  -- SigLIP: 200001, 200002 and 200003 each have a neighbour at about 99 (the twin is not counted, 200003 is); 200004's nearest is 200003 at about 11
  ASSERT (SELECT marks FROM watch.fn_issue_picture_spread(i) WHERE model = 'siglip2' AND step = 90) = 3, 'three marks have a neighbour in the nineties';
  ASSERT (SELECT marks FROM watch.fn_issue_picture_spread(i) WHERE model = 'siglip2' AND step = 10) = 1, 'one mark stands apart';
  ASSERT (SELECT sum(marks) FROM watch.fn_issue_picture_spread(i) WHERE model = 'siglip2') = 4, 'every mark with a vector is counted once';
  -- DINOv3: only two marks have its vector; each is the other's nearest at 60
  ASSERT (SELECT marks FROM watch.fn_issue_picture_spread(i) WHERE model = 'dinov3' AND step = 60) = 2 AND (SELECT sum(marks) FROM watch.fn_issue_picture_spread(i) WHERE model = 'dinov3') = 2, 'the two models are counted apart';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN PERFORM * FROM watch.fn_issue_picture_spread(gen_random_uuid()); ASSERT false, 'an account must not see the spread';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0093 TESTS PASSED
