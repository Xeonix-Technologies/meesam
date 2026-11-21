-- Tests for migration 0068: who verifies a mark read by the AI reader, what a correction keeps, and removal.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t68.rev', platform.fn_staff_invite('rev@x68.test', 'Rev SixtyEight', 'publication_reviewer')::text, false);
SELECT set_config('t68.adm', platform.fn_staff_invite('adm@x68.test', 'Adm SixtyEight', 'system_admin')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('rev@x68.test', 'adm@x68.test');
CREATE TEMP TABLE _i AS
  WITH q AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'),
       a AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T68-A', current_date - 2, 'QA/national_bulletin/T68-A_x.pdf' FROM q RETURNING id),
       u AS (INSERT INTO watch.read_run (issue_id, model, token_cap) SELECT id, 'claude-sonnet-5-5', 100000 FROM a RETURNING id)
  SELECT a.id AS issue, u.id AS run, q.registry_id FROM a, u, q;
GRANT SELECT ON _i TO PUBLIC;
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := (SELECT run FROM _i); BEGIN
  PERFORM watch.fn_read_mark_store(v, '{"page":17,"application_no":"193900","mark_text_ar":"علامة","classes":[3],"applicant_name":"Ownr One","applicant_country":"QA","agent_name":"Agent","agent_city":"Doha","filing_date":"2026-05-01","confidence":0.9}');
  PERFORM watch.fn_read_mark_store(v, '{"page":18,"application_no":"193901","classes":[5],"applicant_name":"Owner Two"}');
  PERFORM watch.fn_read_mark_store(v, '{"page":19,"application_no":null,"classes":[]}');
  PERFORM watch.fn_mark_page_set((SELECT issue FROM _i), (SELECT id FROM watch.published_mark WHERE issue_id = (SELECT issue FROM _i) AND application_no = '193900'), 'QA/x.pages/p17-17.pdf', 17, 17);
END $$;
RESET ROLE;
CREATE TEMP TABLE _m AS SELECT id, application_no FROM watch.published_mark WHERE issue_id = (SELECT issue FROM _i);
GRANT SELECT ON _m TO PUBLIC;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t68.adm'), true);
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM watch.fn_mark_verify((SELECT issue FROM _i), (SELECT id FROM _m WHERE application_no = '193900')); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN PERFORM watch.fn_mark_reject((SELECT issue FROM _i), (SELECT id FROM _m WHERE application_no IS NULL), 'x'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 2, 'only a publication reviewer or the watch operations lead verifies or removes a mark';
END $$;
SELECT set_config('meesam.user_id', current_setting('t68.rev'), true);
DO $$ DECLARE i uuid := (SELECT issue FROM _i); a uuid := (SELECT id FROM _m WHERE application_no = '193900'); b uuid := (SELECT id FROM _m WHERE application_no = '193901');
  z uuid := (SELECT id FROM _m WHERE application_no IS NULL); c text[]; refused integer := 0; BEGIN
  BEGIN PERFORM watch.fn_mark_verify(i, a, '{"classes":[3,46]}'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_mark_verify(i, a, '{"applicant_country":"Qatar"}'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_mark_verify(i, a, '{"application_no":"193-901"}'); EXCEPTION WHEN unique_violation THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_mark_reject(i, z, '  '); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 4, 'a class outside 1 to 45, a country that is not a code, a number another mark carries, and a removal without a reason are refused';
  c := watch.fn_mark_verify(i, a, '{"application_no":"193900","applicant_name":" Owner One ","classes":[3,5],"mark_text_ar":"علامة","agent_city":"Doha","filing_date":"2026-05-01"}');
  ASSERT c = ARRAY['classes', 'applicant_name'], 'the corrected fields are reported: ' || c::text;
  c := watch.fn_mark_verify(i, b);
  ASSERT c = '{}', 'a mark confirmed as read has no correction';
  BEGIN PERFORM watch.fn_mark_verify(i, b); RAISE EXCEPTION 'verified twice'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
  BEGIN PERFORM watch.fn_mark_reject(i, b, 'not a mark'); RAISE EXCEPTION 'a verified mark was removed'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
  PERFORM watch.fn_mark_reject(i, z, 'An index row, not an entry');
END $$;
RESET ROLE;
DO $$ DECLARE m watch.published_mark; BEGIN
  SELECT x.* INTO m FROM watch.published_mark x WHERE x.issue_id = (SELECT issue FROM _i) AND x.application_no = '193900';
  ASSERT m.verify_state = 'human_verified' AND m.verified_by_user_id = current_setting('t68.rev')::uuid AND m.applicant_name = 'Owner One' AND m.classes = '{3,5}', 'the mark is verified with the corrections';
  ASSERT m.extraction -> 'read' ->> 'applicant_name' = 'Ownr One' AND m.extraction -> 'read' -> 'classes' = '[3]'::jsonb AND m.extraction -> 'corrected' = '["classes", "applicant_name"]'::jsonb, 'what the reader gave is kept beside the correction';
  ASSERT m.extraction ->> 'page_key' = 'QA/x.pages/p17-17.pdf' AND m.extraction ->> 'agent_city' = 'Doha' AND m.extraction ? 'verified_at', 'the page file and the other fields stay';
  ASSERT (SELECT count(*) FROM watch.published_mark WHERE issue_id = (SELECT issue FROM _i)) = 2, 'the removed mark is gone';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE table_name = 'published_mark' AND user_id = current_setting('t68.rev')::uuid) = 3
     AND EXISTS (SELECT 1 FROM platform.audit_event WHERE table_name = 'published_mark' AND action = 'DELETE' AND after ->> 'reason' = 'An index row, not an entry'), 'each verification and removal is audited, the removal with its reason';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN ASSERT watch.fn_read_mark_store((SELECT run FROM _i), '{"page":17,"application_no":"193900","classes":[1],"applicant_name":"Other"}') = 'kept', 'a later reading does not touch a verified mark'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0068 TESTS PASSED
