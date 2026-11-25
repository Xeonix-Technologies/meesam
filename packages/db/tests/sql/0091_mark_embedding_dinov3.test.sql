-- Tests for migration 0091: the DINOv3 vector is kept beside the SigLIP 2 one, each with its own engine.
BEGIN;
SET client_min_messages = warning;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T91', current_date - 20, 'AE/national_bulletin/T91_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, extraction)
SELECT issue_id, registry_id, current_date - 20, '372719', '{18}', '{"page":1,"read_by":"labels","image_key":"AE/national_bulletin/T91_x.marks/accepted-p1.png"}'::jsonb FROM _t;
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); a uuid;
  v1 text := '[' || (SELECT string_agg(CASE WHEN g = 1 THEN '1' ELSE '0' END, ',') FROM generate_series(1, 768) g) || ']';
  v2 text := '[' || (SELECT string_agg(CASE WHEN g = 2 THEN '1' ELSE '0' END, ',') FROM generate_series(1, 768) g) || ']';
BEGIN
  SELECT id INTO a FROM watch.published_mark WHERE issue_id = i;
  PERFORM watch.fn_mark_embedding_set(i, a, 'siglip2', v1, 'siglip2-base-patch16-224@aaa+white-square-1', 'ab2bd4d42b6b2a2a');
  PERFORM watch.fn_mark_embedding_set(i, a, 'dinov3', v2, 'dinov3-vitb16-pretrain-lvd1689m@bbb+white-square-1', 'ab2bd4d42b6b2a2a');
  ASSERT (SELECT siglip_embedding IS NOT NULL AND dino_embedding IS NOT NULL AND (siglip_embedding <=> dino_embedding) > 0.99
                 AND extraction ->> 'siglip_engine' = 'siglip2-base-patch16-224@aaa+white-square-1' AND embedding_engine = extraction ->> 'siglip_engine'
                 AND extraction ->> 'dino_engine' = 'dinov3-vitb16-pretrain-lvd1689m@bbb+white-square-1' AND verify_state = 'ai_extracted'
            FROM watch.published_mark WHERE id = a), 'both vectors are kept apart, each with the engine that made it';
  BEGIN PERFORM watch.fn_mark_embedding_set(i, a, 'another', v1, 'x', NULL); ASSERT false, 'a model that is not in use is refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0091 TESTS PASSED
