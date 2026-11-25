-- Tests for migration 0092: look-alikes of one mark by each model, the same picture left out, staff only.
BEGIN;
SET client_min_messages = warning;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T92', current_date - 20, 'AE/national_bulletin/T92_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
-- a vector of 768 numbers from two of them: (a, b, 0, 0, …)
CREATE FUNCTION pg_temp.v(a float8, b float8) RETURNS text LANGUAGE sql AS
  $$ SELECT '[' || a::text || ',' || b::text || ',' || (SELECT string_agg('0', ',') FROM generate_series(1, 766)) || ']' $$;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, mark_text, extraction)
SELECT issue_id, registry_id, current_date - 20, n, c::smallint[], jsonb_build_object('en', w), jsonb_build_object('page', p, 'read_by', 'labels', 'image_key', 'AE/national_bulletin/T92_x.marks/accepted-p' || p || '.png')
  FROM _t, (VALUES ('100001', '{18}', 'ALPHA', 1), ('100002', '{25}', 'ALPHA', 2), ('100003', '{18}', 'ALFA', 3), ('100004', '{9}', 'RINGS', 4), ('100005', '{9}', 'OTHER', 5), ('100006', '{9}', 'NOPIC', 6)) v(n, c, w, p);
UPDATE watch.published_mark SET extraction = extraction - 'image_key' WHERE issue_id = (SELECT issue_id FROM _t) AND application_no = '100006';
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t);
BEGIN
  -- 100001 and 100002 carry the very same picture (same hash). SigLIP finds 100003 nearest, then 100004; DINOv3 the other way round.
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100001'), 'siglip2', pg_temp.v(1, 0), 'S@1', 'aaaaaaaaaaaaaaaa');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100002'), 'siglip2', pg_temp.v(1, 0), 'S@1', 'aaaaaaaaaaaaaaaa');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100003'), 'siglip2', pg_temp.v(0.9, 0.1), 'S@1', 'bbbbbbbbbbbbbbbb');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100004'), 'siglip2', pg_temp.v(0.5, 0.5), 'S@1', 'cccccccccccccccc');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100005'), 'siglip2', pg_temp.v(0.9, 0.1), 'S@OLD', 'dddddddddddddddd');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100001'), 'dinov3', pg_temp.v(1, 0), 'D@1', 'aaaaaaaaaaaaaaaa');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100003'), 'dinov3', pg_temp.v(0.2, 0.8), 'D@1', 'bbbbbbbbbbbbbbbb');
  PERFORM watch.fn_mark_embedding_set(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '100004'), 'dinov3', pg_temp.v(0.8, 0.2), 'D@1', 'cccccccccccccccc');
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); a uuid; r record; n int; BEGIN
  SELECT id INTO a FROM watch.published_mark WHERE issue_id = i AND application_no = '100001';
  SELECT count(*) INTO n FROM watch.fn_mark_lookalikes(i, a, 10);
  ASSERT n = 2, 'the same picture, the mark without a picture and the mark of another engine are left out; two remain: ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_mark_lookalikes(i, a, 10) x WHERE x.application_no IN ('100001', '100002', '100005', '100006')), 'never the mark itself, its twin, a mark without a picture, or a vector made by another engine';
  SELECT * INTO r FROM watch.fn_mark_lookalikes(i, a, 10) x WHERE x.application_no = '100003';
  ASSERT r.rank_siglip = 1 AND r.rank_dino = 2 AND r.siglip > 99 AND r.dino < 30 AND r.mark_en = 'ALFA', 'SigLIP puts 100003 first, DINOv3 second: ' || r.rank_siglip || '/' || r.rank_dino || ' ' || r.siglip || '/' || r.dino;
  SELECT * INTO r FROM watch.fn_mark_lookalikes(i, a, 10) x WHERE x.application_no = '100004';
  ASSERT r.rank_siglip = 2 AND r.rank_dino = 1 AND r.siglip BETWEEN 70 AND 71 AND r.dino > 96, 'DINOv3 puts 100004 first: ' || r.siglip || '/' || r.dino;
  ASSERT (SELECT count(*) FROM watch.fn_mark_lookalikes(i, a, 1)) = 2, 'the first by each model: two marks';
  ASSERT (SELECT x.application_no FROM watch.fn_mark_lookalikes(i, a, 1) x ORDER BY x.rank_siglip NULLS LAST LIMIT 1) = '100003', 'the first by SigLIP';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN PERFORM * FROM watch.fn_mark_lookalikes(gen_random_uuid(), gen_random_uuid(), 10); ASSERT false, 'an account must not see look-alikes';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue') AND status = 'queued' AND payload ->> 'issue_id' = (SELECT issue_id::text FROM _t)) = 0, 'looking compares nothing for alerts';
END $$;
ROLLBACK;
\echo ALL 0092 TESTS PASSED
