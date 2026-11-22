-- Tests for migration 0082: a mark read by rules, complete and in the office's list, needs no person; a whole issue
-- is compared as one job; a trademark added later is compared with the last year's publications.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t82.lead', platform.fn_staff_invite('lead@x82.test', 'Lead EightyTwo', 'watch_lead')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'lead@x82.test';
DO $$ BEGIN
  ASSERT (SELECT s.fetch_spec -> 'read' ->> 'accept' = 'complete_and_listed' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'), 'Türkiye: retired for marks read by rules, as a setting';
  ASSERT (SELECT (rules ->> 'backfill_days')::int = 365 AND rules ? 'weights' FROM watch.engine_config ORDER BY version DESC LIMIT 1), 'the look-back is a setting, added to the engine settings in force';
END $$;
-- an owner watching Türkiye with "oro selekt"
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000082a1', 'owner_individual', '{"en": "Owner EightyTwo"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000082f1', '00000000-0000-0000-0000-0000000082a1', '{"en": "oro selekt"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000082e1'::uuid, '00000000-0000-0000-0000-0000000082f1'::uuid, id, '820100', '{"en": "oro selekt"}'::jsonb, 'existing', 'free_loaded' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000082e1', id, 'filed' FROM registry.registry WHERE code = 'AE';
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T82', current_date - 146, 'TR/national_bulletin/T82_x.pdf' FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _t TO PUBLIC;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, true, true FROM _t
  ON CONFLICT (registry_id) DO UPDATE SET may_store = true, may_show = true, may_derive = true;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t82.lead'), true);
SELECT set_config('t82.run', watch.fn_read_run_request((SELECT issue_id FROM _t), 'x')::text, false);
RESET ROLE;
DELETE FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue', 'watch.compare_record');
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := current_setting('t82.run')::uuid; n integer; BEGIN
  UPDATE watch.read_run SET status = 'done' WHERE id = v;
  INSERT INTO watch.read_part (run_id, seq, kind, from_page, to_page, status, result) VALUES (v, 1, 'index', 9, 9, 'done', '{"rows":[{"application_no":"2026/069330"},{"application_no":"2026/069333"},{"application_no":"2026/069365"}]}');
  PERFORM watch.fn_read_mark_store(v, '{"page":3,"page_to":3,"application_no":"2026/069330","mark_text_en":"oro","classes":[32],"applicant_name":"A","confidence":1,"read_by":"codes"}');
  PERFORM watch.fn_read_mark_store(v, '{"page":3,"page_to":4,"application_no":"2026/069333","mark_text_en":"çizgi kursları","classes":[16],"applicant_name":"B","confidence":1,"read_by":"codes"}');
  PERFORM watch.fn_read_mark_store(v, '{"page":6,"page_to":6,"application_no":"2026/069365","mark_text_en":"hameya","classes":[],"applicant_name":"C","confidence":0.5,"read_by":"codes","notes":"not found in the entry: classes, goods"}');
  PERFORM watch.fn_read_mark_store(v, '{"page":7,"page_to":7,"application_no":"2026/099999","mark_text_en":"stray","classes":[5],"applicant_name":"D","confidence":1,"read_by":"codes"}');
  n := watch.fn_read_run_accept(v);
  ASSERT n = 2, 'the two complete marks that the office lists are accepted: ' || n;
  ASSERT watch.fn_read_run_accept(v) = 0, 'accepting again changes nothing';
END $$;
RESET ROLE;
DO $$ DECLARE i uuid := (SELECT issue_id FROM _t); BEGIN
  ASSERT (SELECT verify_state = 'waived' AND extraction ->> 'accepted' = 'rules' FROM watch.published_mark WHERE issue_id = i AND application_no = '2026/069330'), 'accepted by rules, and it says so';
  ASSERT (SELECT verify_state = 'ai_extracted' FROM watch.published_mark WHERE issue_id = i AND application_no = '2026/069365'), 'an incomplete mark still waits for a person';
  ASSERT (SELECT verify_state = 'ai_extracted' FROM watch.published_mark WHERE issue_id = i AND application_no = '2026/099999'), 'a mark the office''s list does not carry still waits for a person';
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare' AND status = 'queued') = 0 AND (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_issue' AND status = 'queued' AND payload ->> 'issue_id' = i::text) = 1,
    'the whole issue is compared as one job, not one per mark';
  ASSERT watch.fn_compare_issue(i) = 0, 'nothing watches Türkiye yet: no alert';
END $$;
-- the trademark is added to Türkiye afterwards: the publication is 146 days old, its period long ended; the alert is raised all the same
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000082e1', registry_id, 'watch_only' FROM _t;
DO $$ DECLARE a watch.alert; BEGIN
  ASSERT watch.fn_compare_record('00000000-0000-0000-0000-0000000082e1') = 1, 'a trademark added to a registry later is compared with the last year''s publications';
  SELECT * INTO a FROM watch.alert WHERE record_id = '00000000-0000-0000-0000-0000000082e1';
  ASSERT a.risk_band = 'high' AND a.account_id = '00000000-0000-0000-0000-0000000082a1', 'the Turkish "oro" against "oro selekt": High';
END $$;
-- a mark a person verifies one by one is still queued on its own; compare again is one job
DELETE FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_issue');
UPDATE watch.published_mark SET verify_state = 'human_verified' WHERE issue_id = (SELECT issue_id FROM _t) AND application_no = '2026/099999';
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t82.lead'), true);
DO $$ BEGIN ASSERT watch.fn_issue_compare_again((SELECT issue_id FROM _t)) = 3, 'compare again counts the marks'; END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare' AND status = 'queued') = 1, 'one mark verified by a person: its own job';
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_issue' AND status = 'queued') = 1, 'compare again: one job for the issue';
END $$;
-- a reading by the AI reader is never accepted this way
DO $$ DECLARE v uuid; BEGIN
  INSERT INTO watch.read_run (issue_id, model, status, token_cap) VALUES ((SELECT issue_id FROM _t), 'claude-sonnet-5-5', 'done', 100000) RETURNING id INTO v;
  ASSERT watch.fn_read_run_accept(v) = 0, 'marks read by the AI reader still wait for a person';
END $$;
ROLLBACK;
\echo ALL 0082 TESTS PASSED
