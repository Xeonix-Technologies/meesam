-- Tests for migration 0087: the UAE bulletin is read by its printed labels; a person verifies every mark until
-- "complete" is ruled; the other parts of an issue are kept as notices, apart from the published marks.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t87.lead', platform.fn_staff_invite('lead@x87.test', 'Lead EightySeven', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'lead@x87.test';
DO $$ DECLARE r jsonb; BEGIN
  SELECT s.fetch_spec -> 'read' INTO r FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin';
  ASSERT r ->> 'method' = 'labels' AND r ->> 'prepare' = 'arabic_order', 'the UAE is read by labels, its Arabic put in reading order first';
  ASSERT NOT (r ? 'accept'), 'no mark of the UAE is accepted without a person yet';
  ASSERT jsonb_array_length(r -> 'forms') = 10, 'ten forms: accepted, six kinds of change, Madrid, registrations, renewals';
  ASSERT (SELECT count(*) FROM jsonb_array_elements(r -> 'forms') f WHERE f ->> 'kind' = 'marks') = 2, 'two parts publish marks for the watch: accepted and Madrid';
  ASSERT (SELECT f ->> 'number_prefix' FROM jsonb_array_elements(r -> 'forms') f WHERE f ->> 'key' = 'madrid') = 'IR ', 'a Madrid number is marked as an international registration';
  ASSERT (SELECT bool_and(f ->> 'key' ~ '^[a-z0-9_]{1,40}$') FROM jsonb_array_elements(r -> 'forms') f), 'every form has a proper name';
  ASSERT (SELECT s.fetch_spec -> 'read' ->> 'accept' = 'complete_and_listed' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'), 'Türkiye keeps its own setting';
END $$;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T87', current_date - 20, 'AE/national_bulletin/T87_x.rar', 'rar' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id, s.id AS source_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, true, true FROM _t
  ON CONFLICT (registry_id) DO UPDATE SET may_store = true, may_show = true, may_derive = true;
-- the lead asks for the whole issue: no model, no layout marker, no page limit
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t87.lead'), true);
SELECT set_config('t87.run', watch.fn_read_run_request((SELECT issue_id FROM _t), NULL)::text, false);
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT model = 'rules' FROM watch.read_run WHERE id = current_setting('t87.run')::uuid), 'a source read by labels is read by rules';
END $$;
DELETE FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue');
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := current_setting('t87.run')::uuid; n integer; BEGIN
  UPDATE watch.read_run SET status = 'done' WHERE id = v;
  PERFORM watch.fn_read_mark_store(v, '{"page":1,"page_to":1,"file":"accepted.pdf","part":"accepted","application_no":"429012","filing_date":"2026-09-09","mark_text_en":"metersbonwe","classes":[18],"applicant_name":"A","confidence":1,"read_by":"labels"}');
  PERFORM watch.fn_read_mark_store(v, '{"page":2,"page_to":3,"file":"accepted.pdf","part":"accepted","application_no":"490492","mark_text_ar":"بيوتي","classes":[35],"applicant_name":"B","confidence":0.5,"read_by":"labels","notes":"not found in the notice: date"}');
  PERFORM watch.fn_read_mark_store(v, '{"page":1,"page_to":1,"file":"madrid.pdf","part":"madrid","application_no":"IR 429012","international_no":"429012","classes":[12],"applicant_name":"C","confidence":1,"read_by":"labels"}');
  ASSERT watch.fn_read_run_accept(v) = 0, 'the UAE: every mark waits for a person';
  n := watch.fn_read_notices_store(v, 'transfer', '[{"part":"transfer","file":"t.pdf","page":1,"page_to":1,"application_no":"001390","complete":true,"fields":{"number":"001390","mark":"ARPEGE","new_owner":"X"}},
                                                    {"part":"transfer","file":"t.pdf","page":2,"page_to":2,"application_no":null,"complete":false,"fields":{"mark":"DOUX"}}]', true);
  ASSERT n = 2, 'two notices stored: ' || n;
  ASSERT watch.fn_read_notices_store(v, 'transfer', '[{"file":"t.pdf","page":3,"page_to":3,"application_no":"003364","complete":true,"fields":{"number":"003364"}}]', false) = 1, 'a further lot of the same part is added';
  ASSERT watch.fn_read_notices_store(v, 'renewed', '[{"file":"r.pdf","page":1,"page_to":1,"application_no":"013306","complete":true,"fields":{"number":"013306"}}]', true) = 1, 'another part';
END $$;
RESET ROLE;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); n watch.published_notice; BEGIN
  ASSERT (SELECT count(*) FROM watch.published_mark WHERE issue_id = i) = 3, 'the national 429012 and the international registration 429012 are two marks, not one';
  ASSERT (SELECT count(*) FROM watch.published_mark WHERE issue_id = i AND verify_state = 'ai_extracted') = 3, 'all three wait for a person';
  ASSERT (SELECT extraction ->> 'part' = 'madrid' AND extraction ->> 'file' = 'madrid.pdf' AND extraction ->> 'international_no' = '429012' FROM watch.published_mark WHERE issue_id = i AND application_no = 'IR 429012'), 'a mark keeps the part and the file it was read from';
  ASSERT (SELECT count(*) FROM watch.published_notice WHERE issue_id = i) = 4 AND (SELECT count(*) FROM watch.published_notice WHERE issue_id = i AND part = 'transfer') = 3, 'the notices are kept apart from the marks';
  SELECT * INTO n FROM watch.published_notice WHERE issue_id = i AND application_no = '001390';
  ASSERT n.fields ->> 'new_owner' = 'X' AND n.source ->> 'file' = 't.pdf' AND n.source ->> 'page' = '1' AND n.source ->> 'read_by' = 'labels' AND n.source ->> 'run_id' = current_setting('t87.run')
     AND n.publication_date = current_date - 20, 'a notice carries what it states and its source';
  ASSERT (SELECT count(*) FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue') AND status = 'queued') = 0, 'nothing is compared: no mark is verified, and a notice is never compared';
END $$;
-- a new reading of a part replaces what the earlier one stored
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := current_setting('t87.run')::uuid; BEGIN
  ASSERT watch.fn_read_notices_store(v, 'transfer', '[{"file":"t.pdf","page":1,"page_to":1,"application_no":"001390","complete":true,"fields":{"number":"001390"}}]', true) = 1, 'read again';
  ASSERT (SELECT count(*) FROM watch.published_notice WHERE part = 'transfer' AND issue_id = (SELECT issue_id FROM _t)) = 1, 'the earlier notices of the part are replaced';
  ASSERT (SELECT count(*) FROM watch.published_notice WHERE part = 'renewed' AND issue_id = (SELECT issue_id FROM _t)) = 1, 'another part is left alone';
  BEGIN PERFORM watch.fn_read_notices_store(v, 'Bad Name', '[]', true); ASSERT false, 'a part must have a proper name';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
END $$;
RESET ROLE;
-- staff may read the notices; an account's login may neither read nor store them
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN ASSERT (SELECT count(*) FROM watch.published_notice) >= 2, 'staff read the notices'; END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN PERFORM count(*) FROM watch.published_notice; ASSERT false, 'an account must not read the notices';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM watch.fn_read_notices_store(current_setting('t87.run')::uuid, 'transfer', '[]', false); ASSERT false, 'an account must not store notices';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
-- the day "complete" is ruled for the UAE: the complete marks need no person, the incomplete one still waits
UPDATE watch.publication_source s SET fetch_spec = jsonb_set(s.fetch_spec, '{read,accept}', '"complete"') WHERE s.id = (SELECT source_id FROM _t);
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := current_setting('t87.run')::uuid; n integer; BEGIN
  n := watch.fn_read_run_accept(v);
  ASSERT n = 2, 'the two complete marks are accepted: ' || n;
  ASSERT watch.fn_read_run_accept(v) = 0, 'accepting again changes nothing';
END $$;
RESET ROLE;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); BEGIN
  ASSERT (SELECT verify_state = 'ai_extracted' FROM watch.published_mark WHERE issue_id = i AND application_no = '490492'), 'an incomplete mark still waits for a person';
  ASSERT (SELECT verify_state = 'waived' AND extraction ->> 'accepted' = 'rules' FROM watch.published_mark WHERE issue_id = i AND application_no = '429012'), 'accepted by rules, and it says so';
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_issue' AND status = 'queued' AND payload ->> 'issue_id' = i::text) = 1, 'the issue is then compared as one job';
END $$;
-- the re-use register still decides: nothing of a registry is stored against it
UPDATE watch.reuse_register SET may_store = false WHERE registry_id = (SELECT registry_id FROM _t);
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  BEGIN PERFORM watch.fn_read_notices_store(current_setting('t87.run')::uuid, 'transfer', '[]', false); ASSERT false, 'the re-use register must stop the storing';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0087 TESTS PASSED
