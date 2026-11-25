-- Tests for migration 0090: the worker stores the vector of a mark's picture with the engine that made it.
BEGIN;
SET client_min_messages = warning;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T90', current_date - 20, 'AE/national_bulletin/T90_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, extraction)
SELECT issue_id, registry_id, current_date - 20, n, '{18}', e::jsonb FROM _t,
  (VALUES ('372719', '{"page":1,"read_by":"labels","image_key":"AE/national_bulletin/T90_x.marks/accepted-p1.png"}'), ('372720', '{"page":2,"read_by":"labels"}')) v(n, e);
DELETE FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue');
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); a uuid; b uuid;
  v text := '[' || (SELECT string_agg(CASE WHEN g = 1 THEN '1' ELSE '0' END, ',') FROM generate_series(1, 768) g) || ']';
BEGIN
  SELECT id INTO a FROM watch.published_mark WHERE issue_id = i AND application_no = '372719';
  SELECT id INTO b FROM watch.published_mark WHERE issue_id = i AND application_no = '372720';
  PERFORM watch.fn_mark_embedding_set(i, a, 'siglip2', v, 'siglip2-base-patch16-224@abc123def456+white-square-1', 'ab2bd4d42b6b2a2a');
  PERFORM watch.fn_mark_embedding_set(i, b, 'siglip2', v, 'siglip2-base-patch16-224@abc123def456+white-square-1', NULL);
  ASSERT (SELECT siglip_embedding IS NOT NULL AND vector_dims(siglip_embedding) = 768 AND dino_embedding IS NULL
                 AND embedding_engine = 'siglip2-base-patch16-224@abc123def456+white-square-1' AND extraction ->> 'image_phash' = 'ab2bd4d42b6b2a2a'
                 AND extraction ->> 'siglip_engine' = embedding_engine AND verify_state = 'ai_extracted'
            FROM watch.published_mark WHERE id = a), 'the vector, its engine and the hash are kept; nothing else about the mark changes';
  ASSERT (SELECT siglip_embedding IS NULL FROM watch.published_mark WHERE id = b), 'a mark without a picture gets no vector';
  PERFORM watch.fn_mark_embedding_failed(i, a, 'the picture could not be opened');
  ASSERT (SELECT extraction ->> 'embed_failed' = 'the picture could not be opened' AND siglip_embedding IS NOT NULL FROM watch.published_mark WHERE id = a), 'a failure is noted on the mark';
  BEGIN PERFORM watch.fn_mark_embedding_set(i, a, 'another', v, 'x', NULL); ASSERT false, 'a model that is not in use is refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM watch.fn_mark_embedding_set(i, a, 'siglip2', v, ' ', NULL); ASSERT false, 'a vector must name its engine';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  BEGIN PERFORM watch.fn_mark_embedding_set(i, a, 'siglip2', '[1,2,3]', 'e', NULL); ASSERT false, 'a vector of another length is refused';
  EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue') AND status = 'queued') = 0, 'storing a vector compares nothing';
END $$;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN PERFORM watch.fn_mark_embedding_set(gen_random_uuid(), gen_random_uuid(), 'siglip2', '[1]', 'e', NULL); ASSERT false, 'an account must not store vectors';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0090 TESTS PASSED
