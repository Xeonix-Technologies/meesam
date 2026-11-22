-- Tests for migration 0081: why no alert was raised is visible in counts; compare again; reading by printed codes.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t81.lead', platform.fn_staff_invite('lead@x81.test', 'Lead EightyOne', 'watch_lead')::text, false);
SELECT set_config('t81.rev', platform.fn_staff_invite('rev@x81.test', 'Rev EightyOne', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x81.test', 'rev@x81.test');

-- the Founder's case: an owner whose name is written in one script only, "oro selekt" (class 35), and "ORO LABS" (class 32)
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000081a1', 'owner_individual', '{"en": "Owner EightyOne"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000081f1', '00000000-0000-0000-0000-0000000081a1', '{"en": "oro selekt"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000081e1'::uuid, '00000000-0000-0000-0000-0000000081f1'::uuid, id, '810100', '{"en": "oro selekt"}'::jsonb, 'existing', 'free_loaded' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_class (record_id, nice_class_id) SELECT '00000000-0000-0000-0000-0000000081e1', id FROM registry.nice_class WHERE number = 35;
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000081e1', id, 'filed' FROM registry.registry WHERE code = 'AE';
CREATE TEMP TABLE _i AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T81', current_date - 70 FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _i TO PUBLIC;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, NULL, true FROM _i
  ON CONFLICT (registry_id) DO UPDATE SET may_store = true, may_show = NULL, may_derive = true;
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state)
  SELECT '00000000-0000-0000-0000-0000000081b1', issue_id, registry_id, current_date - 70, '910001', '{"en": "ORO LABS"}', '{32}', 'Other Co', 'human_verified' FROM _i;
DO $$ DECLARE c watch.candidate; s record; g uuid := (SELECT registry_id FROM _i); BEGIN
  PERFORM watch.fn_compare(g, current_date - 70, '00000000-0000-0000-0000-0000000081b1');
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000081b1';
  ASSERT c.score = 0.8 AND c.explanation ->> 'own' = 'false' AND c.explanation ->> 'held' = 'reuse_show', '"own" is never left unknown: ' || (c.explanation ->> 'own');
  ASSERT NOT EXISTS (SELECT 1 FROM watch.alert), 'held back while "show" is not confirmed';
  SELECT * INTO s FROM watch.fn_issue_compare_summary((SELECT issue_id FROM _i));
  ASSERT s.matches = 1 AND s.alerts = 0 AND s.held = 1 AND s.own = 0 AND s.low = 0 AND s.watched >= 1 AND s.may_show IS FALSE, 'the console counts the held match and the watched trademarks: ' || s.held || '/' || s.watched;
END $$;
-- "show" is confirmed; the issue is older than the registry's opposition period, so the lead asks for it to be compared again
UPDATE watch.reuse_register SET may_show = true WHERE registry_id = (SELECT registry_id FROM _i);
DELETE FROM platform.job WHERE kind IN ('watch.compare', 'watch.compare_registry');
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t81.rev'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_issue_compare_again((SELECT issue_id FROM _i)); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'only the lead has an issue compared again';
END $$;
SELECT set_config('meesam.user_id', current_setting('t81.lead'), true);
DO $$ BEGIN ASSERT watch.fn_issue_compare_again((SELECT issue_id FROM _i)) = 1, 'every verified mark of the issue is queued'; END $$;
RESET ROLE;
DO $$ DECLARE s record; g uuid := (SELECT registry_id FROM _i); BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare' AND status = 'queued' AND payload ->> 'mark_id' = '00000000-0000-0000-0000-0000000081b1') = 1, 'queued for the worker';
  ASSERT watch.fn_compare(g, current_date - 70, '00000000-0000-0000-0000-0000000081b1') = 1, 'the alert is raised, whatever the issue''s date';
  SELECT * INTO s FROM watch.fn_issue_compare_summary((SELECT issue_id FROM _i));
  ASSERT s.alerts = 1 AND s.held = 0 AND s.may_show, 'and the console shows it';
  ASSERT (SELECT risk_band = 'high' AND account_id = '00000000-0000-0000-0000-0000000081a1' FROM watch.alert), 'High, for the account that holds the trademark';
END $$;

-- reading by printed codes: Türkiye carries the settings
DO $$ DECLARE r jsonb; BEGIN
  SELECT s.fetch_spec -> 'read' INTO r FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin';
  ASSERT r ->> 'method' = 'codes' AND r #>> '{codes,number}' = '210' AND r #>> '{codes,goods}' = '510' AND r ->> 'agent_label' = 'Vekil:' AND r #>> '{wording_kinds,şekil}' = 'device'
     AND r ->> 'sections' = 'İlan Edildiği Bölüm' AND r ->> 'number_pattern' = '\d{4}/\d{6}', 'Türkiye''s codes, labels and section heading are data on the source';
END $$;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T81-TR', current_date - 5, 'TR/national_bulletin/T81_x.pdf' FROM s RETURNING id)
  SELECT i.id AS issue_id FROM i;
GRANT SELECT ON _t TO PUBLIC;
-- six AI readings in the last day: the daily limit is reached for AI readings
INSERT INTO watch.read_run (issue_id, model, status, token_cap, created_at) SELECT (SELECT issue_id FROM _i), 'claude-sonnet-5-5', 'done', 100000, now() - interval '1 hour' FROM generate_series(1, 6);
DELETE FROM platform.job WHERE kind IN ('watch.read_run', 'watch.mark_pages');
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t81.lead'), true);
DO $$ DECLARE v uuid; BEGIN
  v := watch.fn_read_run_request((SELECT issue_id FROM _t), 'claude-sonnet-5-5');
  ASSERT (SELECT model = 'rules' AND status = 'queued' AND from_page IS NULL FROM watch.read_run WHERE id = v), 'a source read by codes asks no AI model, needs no entry marker and is not held by the daily limit';
  PERFORM watch.fn_read_run_stop(v);
  v := watch.fn_read_run_request((SELECT issue_id FROM _t), '', NULL, 9, 3468);
  ASSERT (SELECT from_page = 9 AND to_page = 3468 FROM watch.read_run WHERE id = v), 'and any range of pages can be asked';
END $$;
RESET ROLE;
-- the worker stores what the rules read, exactly as a mark read by the AI reader: waiting for a person
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE v uuid := (SELECT id FROM watch.read_run WHERE issue_id = (SELECT issue_id FROM _t) ORDER BY created_at DESC LIMIT 1); BEGIN
  ASSERT watch.fn_read_mark_store(v, '{"page":2521,"page_to":2521,"printed_page":"2521","application_no":"2026/069330","filing_date":"2026-06-02","mark_text_en":"oro","classes":[32],"goods":"Biralar; bira yapımında kullanılan preparatlar.","applicant_name":"GÜRPA GÜRTEKİN PAZARLAMA VE TİCARET ANONİM ŞİRKETİ","applicant_country":"TR","agent_name":"SERCAN DOLANBAY","confidence":1,"read_by":"codes"}') = 'inserted', 'stored';
END $$;
RESET ROLE;
DO $$ DECLARE m watch.published_mark; BEGIN
  SELECT x.* INTO m FROM watch.published_mark x JOIN _t ON x.issue_id = _t.issue_id;
  ASSERT m.verify_state = 'ai_extracted' AND m.mark_text = '{"en": "oro"}' AND m.classes = '{32}' AND m.extraction ->> 'model' = 'rules' AND m.extraction ->> 'read_by' = 'codes' AND m.extraction ->> 'page_to' = '2521',
    'a mark read by rules waits for a person, and says how it was read';
END $$;
-- its page is cut out when a reviewer opens it
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t81.rev'), true);
SELECT watch.fn_mark_pages_request(m.issue_id, m.id) FROM watch.published_mark m JOIN _t ON m.issue_id = _t.issue_id;
SELECT watch.fn_mark_pages_request(m.issue_id, m.id) FROM watch.published_mark m JOIN _t ON m.issue_id = _t.issue_id;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.mark_pages' AND status = 'queued' AND payload ? 'from_mark' AND (payload ->> 'limit')::int = 25) = 1, 'asked once, for that mark and the ones after it';
END $$;
SET LOCAL ROLE meesam_app;
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM watch.fn_mark_pages_request(gen_random_uuid(), gen_random_uuid()); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN PERFORM watch.fn_issue_compare_again(gen_random_uuid()); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 2, 'an account can ask for neither';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0081 TESTS PASSED
