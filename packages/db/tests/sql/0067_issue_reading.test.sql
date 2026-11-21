-- Tests for migration 0067: reading a whole issue — who may ask, what is stored, and the comparison with the index.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t67.lead', platform.fn_staff_invite('lead@x67.test', 'Lead SixtySeven', 'watch_lead')::text, false);
SELECT set_config('t67.rev', platform.fn_staff_invite('rev@x67.test', 'Rev SixtySeven', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x67.test', 'rev@x67.test');
CREATE TEMP TABLE _i AS
  WITH q AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'),
       e AS (SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       a AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T67-A', current_date - 2, 'QA/national_bulletin/T67-A_x.pdf' FROM q RETURNING id),
       b AS (INSERT INTO watch.publication_issue (source_id, issue_no, object_key) SELECT id, 'T67-B', 'QA/national_bulletin/T67-B_x.pdf' FROM q RETURNING id),
       c AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T67-C', current_date - 2, 'AE/national_bulletin/T67-C_x.rar' FROM e RETURNING id)
  SELECT a.id AS qa, b.id AS undated, c.id AS no_layout, q.registry_id FROM a, b, c, q;
GRANT SELECT ON _i TO PUBLIC;
UPDATE watch.publication_source s SET fetch_spec = s.fetch_spec - 'read' FROM registry.registry g WHERE g.id = s.registry_id AND g.code = 'AE';
DELETE FROM platform.job WHERE kind = 'watch.read_run';

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t67.rev'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_read_run_request((SELECT qa FROM _i), 'claude-sonnet-5-5'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'only the watch operations lead may ask for a whole issue to be read';
END $$;
SELECT set_config('meesam.user_id', current_setting('t67.lead'), true);
DO $$ DECLARE refused integer := 0; v uuid; BEGIN
  BEGIN PERFORM watch.fn_read_run_request((SELECT undated FROM _i), 'claude-sonnet-5-5'); EXCEPTION WHEN null_value_not_allowed THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_read_run_request((SELECT no_layout FROM _i), 'claude-sonnet-5-5'); EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := refused + 1; END;
  ASSERT refused = 2, 'an issue with no publication date, or of a registry whose layout is not entered, is refused';
  v := watch.fn_read_run_request((SELECT qa FROM _i), 'claude-sonnet-5-5');
  PERFORM set_config('t67.run', v::text, false);
  ASSERT (SELECT status = 'queued' AND token_cap = 3000000 FROM watch.read_run WHERE id = v), 'a run is queued with its ceiling';
  BEGIN PERFORM watch.fn_read_run_request((SELECT qa FROM _i), 'claude-sonnet-5-5'); RAISE EXCEPTION 'a second run of the same issue should be refused'; EXCEPTION WHEN unique_violation THEN NULL; END;
  ASSERT (SELECT fetch_spec -> 'read' ->> 'index' = 'before_entries' AND fetch_spec -> 'read' ->> 'entry_start' = 'قدم عنها الطلب رقم' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'), 'Qatar carries where an entry begins and that an index is printed before the entries';
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.read_run' AND status = 'queued') = 1, 'the run is queued for the worker'; END $$;

-- the worker: parts, marks, outcome
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := current_setting('t67.run')::uuid; s text; BEGIN
  UPDATE watch.read_run SET status = 'reading', entries_found = 3 WHERE id = v;
  INSERT INTO watch.read_part (run_id, seq, kind, from_page, to_page, status, result) VALUES
    (v, 1, 'index', 1, 6, 'done', '{"rows":[{"application_no":"193900","class":3,"page":"12"},{"application_no":"193901","class":"5","page":"13"},{"application_no":"193 902","class":9,"page":"14"},{"application_no":"193900","class":3,"page":"12"}]}'),
    (v, 2, 'entries', 7, 9, 'done', '{}'),
    (v, 3, 'entries', 10, 12, 'failed', NULL);
  UPDATE watch.read_part SET error = 'AI reader: 529 overloaded' WHERE run_id = v AND seq = 3;
  s := watch.fn_read_mark_store(v, '{"page":7,"application_no":"193900","mark_text_ar":"علامة","mark_text_en":" ","classes":[3,3,"x",99],"applicant_name":"Owner One","applicant_country":"qa","agent_name":"Agent","goods":"soap","confidence":0.9,"filing_date":"2026-05-01"}');
  ASSERT s = 'inserted', 'a mark read is stored';
  s := watch.fn_read_mark_store(v, '{"page":8,"application_no":"193901","classes":[35],"applicant_country":"Qatar"}');
  s := watch.fn_read_mark_store(v, '{"page":9,"application_no":"200000","classes":[1]}');
  s := watch.fn_read_mark_store(v, '{"page":9,"application_no":null,"classes":[1]}');
  s := watch.fn_read_mark_store(v, '{"page":9,"application_no":null,"classes":[2]}');
  ASSERT s = 'updated', 'a mark without a number is the same mark when read again on the same page';
  s := watch.fn_read_mark_store(v, '{"page":7,"application_no":"193-900","classes":[3],"applicant_name":"Owner One LLC","applicant_country":"qa"}');
  ASSERT s = 'updated', 'the same number read again brings the unverified mark up to date';
END $$;
RESET ROLE;
DO $$ DECLARE v uuid := current_setting('t67.run')::uuid; o jsonb; m watch.published_mark; BEGIN
  SELECT x.* INTO m FROM watch.published_mark x JOIN _i ON x.issue_id = _i.qa WHERE core.fn_number_key(x.application_no) = '193900';
  ASSERT m.verify_state = 'ai_extracted' AND m.classes = '{3}' AND m.applicant_country = 'QA' AND m.applicant_name = 'Owner One LLC' AND m.publication_date = current_date - 2, 'stored waiting for verification, with clean classes and country';
  ASSERT m.mark_text IS NULL AND m.extraction ->> 'run_id' = v::text AND m.extraction ->> 'model' = 'claude-sonnet-5-5' AND m.extraction ->> 'page' = '7', 'what else was read stays beside the mark, with the run and the model';
  ASSERT (SELECT applicant_country IS NULL FROM watch.published_mark x JOIN _i ON x.issue_id = _i.qa WHERE x.application_no = '193901'), 'a country that is not a two-letter code is left empty';
  ASSERT (SELECT count(*) FROM watch.published_mark x JOIN _i ON x.issue_id = _i.qa) = 4, 'four marks: no mark is stored twice';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.record_match), 'an unverified mark is matched to no trademark';
  o := watch.fn_read_run_outcome(v);
  ASSERT (o ->> 'index_rows')::int = 3 AND (o ->> 'marks')::int = 4 AND (o ->> 'without_number')::int = 1 AND (o ->> 'entry_pages')::int = 3, 'the outcome counts the index rows once each, and the marks';
  ASSERT o -> 'missing' = '[{"no": "193 902", "class": 9, "page": "14"}]'::jsonb, 'a number in the index that was not read is listed as missing';
  ASSERT o -> 'not_in_index' = '[{"no": "200000", "page": "9"}]'::jsonb, 'a number read that the index does not list is shown';
  ASSERT jsonb_array_length(o -> 'class_differs') = 1 AND o -> 'class_differs' -> 0 ->> 'no' = '193901', 'a class that differs from the index is shown';
  ASSERT o -> 'pages_not_read' -> 0 ->> 'from' = '10' AND jsonb_array_length(o -> 'pages_not_read') = 1, 'pages that could not be read are listed';
  -- a mark a person has verified is never touched by a later reading
  UPDATE watch.published_mark x SET verify_state = 'human_verified' FROM _i WHERE x.issue_id = _i.qa AND x.application_no = '193901';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN ASSERT watch.fn_read_mark_store(current_setting('t67.run')::uuid, '{"page":8,"application_no":"193901","classes":[5]}') = 'kept', 'a verified mark is kept as verified'; END $$;
RESET ROLE;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t67.rev'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_read_run_stop(current_setting('t67.run')::uuid); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'only the lead stops a run';
  ASSERT (SELECT count(*) FROM watch.published_mark x JOIN _i ON x.issue_id = _i.qa) = 4, 'staff can read the published marks in the console';
END $$;
SELECT set_config('meesam.user_id', current_setting('t67.lead'), true);
DO $$ DECLARE v uuid := current_setting('t67.run')::uuid; BEGIN
  PERFORM watch.fn_read_run_stop(v);
  ASSERT (SELECT status = 'stopped' AND finished_at IS NOT NULL FROM watch.read_run WHERE id = v), 'the lead stops a run';
  BEGIN PERFORM watch.fn_read_run_stop(v); RAISE EXCEPTION 'a run that ended cannot be stopped again'; EXCEPTION WHEN no_data_found THEN NULL; END;
  v := watch.fn_read_run_request((SELECT qa FROM _i), 'claude-haiku-5-5', 10);
  ASSERT (SELECT token_cap = 100000 FROM watch.read_run WHERE id = v), 'after a run ended the issue can be read again; the ceiling is kept within bounds';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN ASSERT (SELECT count(*) FROM watch.published_mark) = 0, 'an account sees no unverified mark'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0067 TESTS PASSED
