-- Tests for migration 0070: adding and removing a watch-only registry on a trademark; the console's comparison summary.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000070a1', 'owner_individual', '{"en": "Owner Seventy"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000070a2', 'owner_individual', '{"en": "Stranger Seventy"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000070f1', '00000000-0000-0000-0000-0000000070a1', '{"en": "SEVENTY"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000070e1', '00000000-0000-0000-0000-0000000070f1', id, '700100', '{"en": "Seventy"}', 'existing', 'paid' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000070e1', id, 'filed' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_class (record_id, nice_class_id) SELECT '00000000-0000-0000-0000-0000000070e1', id FROM registry.nice_class WHERE number = 9;
UPDATE watch.publication_source s SET active = true FROM registry.registry g WHERE g.id = s.registry_id AND g.code = 'QA' AND s.stream = 'national_bulletin';
UPDATE watch.publication_source s SET active = false FROM registry.registry g WHERE g.id = s.registry_id AND g.code = 'BH';
CREATE TEMP TABLE _g AS SELECT (SELECT id FROM registry.registry WHERE code = 'QA') AS qa, (SELECT id FROM registry.registry WHERE code = 'BH') AS bh, (SELECT id FROM registry.registry WHERE code = 'AE') AS ae;
GRANT SELECT ON _g TO PUBLIC;
DELETE FROM platform.job WHERE kind = 'watch.compare_record';

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000070a2', true);
DO $$ BEGIN
  BEGIN PERFORM core.fn_record_watch_set('00000000-0000-0000-0000-0000000070e1', (SELECT qa FROM _g), true); RAISE EXCEPTION 'a stranger changed the watch'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000070a1', true);
DO $$ DECLARE refused integer := 0; BEGIN
  BEGIN PERFORM core.fn_record_watch_set('00000000-0000-0000-0000-0000000070e1', (SELECT bh FROM _g), true); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM core.fn_record_watch_set('00000000-0000-0000-0000-0000000070e1', (SELECT ae FROM _g), false); EXCEPTION WHEN object_not_in_prerequisite_state THEN refused := refused + 1; END;
  ASSERT refused = 2, 'a registry Meesam does not read cannot be added; the registry where the mark is filed cannot be removed';
  PERFORM core.fn_record_watch_set('00000000-0000-0000-0000-0000000070e1', (SELECT qa FROM _g), true);
  PERFORM core.fn_record_watch_set('00000000-0000-0000-0000-0000000070e1', (SELECT qa FROM _g), true);
  ASSERT (SELECT count(*) FROM core.record_registry_scope WHERE record_id = '00000000-0000-0000-0000-0000000070e1' AND kind = 'watch_only') = 1, 'a watch-only registry is added once';
END $$;
RESET ROLE;
-- a mark published in Qatar is now compared with the trademark filed in the UAE
CREATE TEMP TABLE _i AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T70', current_date - 3 FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, true, true FROM _i
  ON CONFLICT (registry_id) DO UPDATE SET may_store = true, may_show = true, may_derive = true;
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state)
  SELECT '00000000-0000-0000-0000-0000000070b1', issue_id, registry_id, current_date - 3, '800001', '{"en": "SEVENTY"}', '{9}', 'Other Co', 'human_verified' FROM _i;
DO $$ DECLARE s record; BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_record' AND status = 'queued') = 1, 'adding a registry queues the comparison with what it already published';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE table_name = 'record_registry_scope' AND record_id = '00000000-0000-0000-0000-0000000070e1' AND action = 'INSERT' AND account_id = '00000000-0000-0000-0000-0000000070a1') = 1, 'the change is audited with the account that made it';
  SELECT * INTO s FROM watch.fn_issue_compare_summary((SELECT issue_id FROM _i));
  ASSERT s.verified = 1 AND s.compared = 0 AND s.waiting_jobs = 1 AND s.alerts = 0, 'the summary shows a verified mark still waiting to be compared';
  ASSERT watch.fn_compare_record('00000000-0000-0000-0000-0000000070e1') = 1, 'the Qatar publication alerts the trademark filed in the UAE, through its watch-only registry';
  ASSERT (SELECT registry_id = (SELECT qa FROM _g) AND opposition_deadline = current_date - 3 + 60 FROM watch.alert WHERE record_id = '00000000-0000-0000-0000-0000000070e1'), 'the alert is the Qatar registry''s, with the deadline from Qatar''s verified period';
  DELETE FROM platform.job WHERE kind = 'watch.compare';
  SELECT * INTO s FROM watch.fn_issue_compare_summary((SELECT issue_id FROM _i));
  ASSERT s.compared = 1 AND s.matches = 1 AND s.alerts = 1 AND s.held = 0 AND s.own = 0, 'the summary counts matches and alerts';
END $$;
-- a stream whose date basis is not confirmed gives no computed deadline (Qatar's Madrid gazette)
DO $$ DECLARE v_src uuid; v_issue uuid; g uuid := (SELECT qa FROM _g); BEGIN
  SELECT s.id INTO v_src FROM watch.publication_source s WHERE s.registry_id = g AND s.fetch_spec ->> 'deadline_basis' = 'unconfirmed';
  ASSERT v_src IS NOT NULL, 'Qatar''s Madrid gazette is marked: the date its period runs from is not confirmed';
  INSERT INTO watch.publication_issue (source_id, issue_no, published_on) VALUES (v_src, 'T70-MD', current_date - 3) RETURNING id INTO v_issue;
  INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state)
  VALUES ('00000000-0000-0000-0000-0000000070b2', v_issue, g, current_date - 3, 'MD-1', '{"en": "SEVENTY"}', '{9}', 'Other Co', 'human_verified');
  ASSERT watch.fn_compare(g, current_date - 3, '00000000-0000-0000-0000-0000000070b2') = 1, 'the Madrid publication alerts too';
  ASSERT (SELECT a.opposition_deadline IS NULL FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id WHERE c.published_mark_id = '00000000-0000-0000-0000-0000000070b2'), 'with no computed deadline: the account enters it';
END $$;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000070a1', true);
DO $$ BEGIN
  PERFORM core.fn_record_watch_set('00000000-0000-0000-0000-0000000070e1', (SELECT qa FROM _g), false);
  ASSERT (SELECT count(*) FROM core.record_registry_scope WHERE record_id = '00000000-0000-0000-0000-0000000070e1') = 1 AND (SELECT count(*) FROM watch.alert) = 2, 'a watch-only registry is removed; alerts already raised stay';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0070 TESTS PASSED
