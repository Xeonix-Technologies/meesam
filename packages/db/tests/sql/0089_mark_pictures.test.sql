-- Tests for migration 0089: the settings that tell a mark's picture, and noting where the picture is kept.
BEGIN;
SET client_min_messages = warning;
DO $$ DECLARE r jsonb; BEGIN
  SELECT s.fetch_spec -> 'read' INTO r FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin';
  ASSERT (r -> 'picture' ->> 'min')::int = 24 AND r -> 'picture' -> 'not' = '[[292, 97], [606, 200]]'::jsonb, 'the UAE: which image is the mark is told by the settings';
  ASSERT r ->> 'method' = 'labels' AND NOT (r ? 'accept') AND jsonb_array_length(r -> 'forms') = 11, 'nothing else changed';
  ASSERT (SELECT NOT (s.fetch_spec -> 'read' ? 'picture') FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'), 'no other registry has the setting yet';
END $$;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T89', current_date - 20, 'AE/national_bulletin/T89_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, extraction)
SELECT issue_id, registry_id, current_date - 20, '372719', '{18}', '{"page":1,"read_by":"labels","part":"accepted"}' FROM _t;
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); m uuid := (SELECT id FROM watch.published_mark WHERE issue_id = (SELECT issue_id FROM _t)); BEGIN
  PERFORM watch.fn_mark_picture_set(i, m, 'somewhere/else.png', 10, 10);
  ASSERT (SELECT NOT (extraction ? 'image_key') FROM watch.published_mark WHERE id = m), 'a key outside the issue''s pictures is not noted';
  PERFORM watch.fn_mark_picture_set(i, m, 'AE/national_bulletin/T89_x.marks/accepted-p1.png', 502, 228);
  ASSERT (SELECT extraction ->> 'image_key' = 'AE/national_bulletin/T89_x.marks/accepted-p1.png' AND extraction ->> 'image_w' = '502' AND extraction ->> 'image_h' = '228'
                 AND extraction ->> 'has_image' = 'true' AND extraction ->> 'part' = 'accepted' AND verify_state = 'ai_extracted'
            FROM watch.published_mark WHERE id = m), 'the picture is noted beside the mark, and nothing else about the mark changes';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN PERFORM watch.fn_mark_picture_set(gen_random_uuid(), gen_random_uuid(), 'x.marks/p1.png', 1, 1); ASSERT false, 'an account must not note pictures';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0089 TESTS PASSED
