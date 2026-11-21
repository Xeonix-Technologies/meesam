-- Tests for migration 0061: a record is matched to its published mark by number, never merged; the note is advisory.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000061a1', 'owner_individual', '{"en": "Owner SixtyOne"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000061a2', 'owner_individual', '{"en": "Someone Else"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000061f1', '00000000-0000-0000-0000-0000000061a1', '{"en": "ORYX"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000061e1', '00000000-0000-0000-0000-0000000061f1', id, '407-950 ', '{"en": "Oryx Cafe", "ar": "مقهى المها"}', 'new_filing', 'free_new_pending' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_class (record_id, nice_class_id) SELECT '00000000-0000-0000-0000-0000000061e1', id FROM registry.nice_class WHERE number IN (30, 43);
CREATE TEMP TABLE _i AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T61', current_date - 3 FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _i TO PUBLIC;

-- an unverified mark matches nothing
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, extraction)
  SELECT '00000000-0000-0000-0000-0000000061b1', issue_id, registry_id, current_date - 3, '407950', '{"en": "ORYX CAFÉ"}', '{43}', 'Owner Sixty One LLC', '{"page": 17}' FROM _i;
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM watch.record_match), 'a mark still waiting for verification is matched to nothing'; END $$;

-- once verified it is matched by number, however the number was typed
UPDATE watch.published_mark SET verify_state = 'human_verified' WHERE id = '00000000-0000-0000-0000-0000000061b1';
DO $$ DECLARE x watch.record_match; r core.record; BEGIN
  SELECT * INTO x FROM watch.record_match;
  ASSERT x.record_id = '00000000-0000-0000-0000-0000000061e1' AND x.matched_by = 'number', 'matched by registry and number ("407-950 " = "407950")';
  ASSERT jsonb_array_length(x.differences) = 2, 'two differences recorded: ' || x.differences::text;
  ASSERT x.differences @> '[{"field": "mark_text", "lang": "en", "record": "Oryx Cafe", "registry": "ORYX CAFÉ"}]', 'the wording differs';
  ASSERT x.differences @> '[{"field": "classes", "record": [30, 43], "registry": [43]}]', 'the classes differ';
  SELECT * INTO r FROM core.record WHERE id = x.record_id;
  ASSERT r.mark_text = '{"en": "Oryx Cafe", "ar": "مقهى المها"}' AND r.application_no = '407-950 ' AND r.warnings = '[]', 'the record itself is untouched: matched, never merged';
END $$;

-- what the account sees
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000061a1', true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM 1 FROM watch.published_mark LIMIT 1; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied OR NOT EXISTS (SELECT 1 FROM watch.published_mark), 'an account cannot read the published marks directly';
  ASSERT NOT EXISTS (SELECT 1 FROM core.fn_registry_shows('00000000-0000-0000-0000-0000000061e1')), 'no note while the re-use register has not said the data may be shown';
END $$;
RESET ROLE;
UPDATE watch.reuse_register SET may_show = true WHERE registry_id = (SELECT registry_id FROM _i);
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000061a1', true);
DO $$ DECLARE n record; BEGIN
  SELECT * INTO n FROM core.fn_registry_shows('00000000-0000-0000-0000-0000000061e1');
  ASSERT n.issue_no = 'T61' AND n.page = 17 AND n.applicant_name = 'Owner Sixty One LLC' AND n.classes = '{43}', 'the note carries the registry''s own values and their source';
  ASSERT jsonb_array_length(n.differences) = 2, 'and the differences';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000061a2', true);
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM core.fn_registry_shows('00000000-0000-0000-0000-0000000061e1')), 'another account sees nothing'; END $$;
RESET ROLE;

-- the record is corrected by its owner: the note follows, the published data does not change
UPDATE core.record SET mark_text = '{"en": "oryx  cafÉ"}' WHERE id = '00000000-0000-0000-0000-0000000061e1';
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000061a1', true);
DO $$ DECLARE n record; BEGIN
  SELECT * INTO n FROM core.fn_registry_shows('00000000-0000-0000-0000-0000000061e1');
  ASSERT jsonb_array_length(n.differences) = 1 AND n.differences -> 0 ->> 'field' = 'classes', 'case and spacing are not differences; the classes still differ';
  ASSERT n.mark_text = '{"en": "ORYX CAFÉ"}', 'the published wording is as the registry gave it';
END $$;
RESET ROLE;

-- a record entered after the publication is matched too; a changed number drops the old match
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000061f2', '00000000-0000-0000-0000-0000000061a2', '{"en": "LATE"}', 'word');
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, verify_state)
  SELECT '00000000-0000-0000-0000-0000000061b2', issue_id, registry_id, current_date - 3, 'AE/55-1', '{"en": "LATE"}', '{9}', 'human_verified' FROM _i;
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000061e2', '00000000-0000-0000-0000-0000000061f2', registry_id, 'ae 551', '{"en": "LATE"}', 'existing', 'free_loaded' FROM _i;
DO $$ BEGIN
  ASSERT (SELECT differences = '[]'::jsonb FROM watch.record_match WHERE record_id = '00000000-0000-0000-0000-0000000061e2'), 'a record added later is matched to what was already published; nothing differs';
  UPDATE core.record SET application_no = '999' WHERE id = '00000000-0000-0000-0000-0000000061e2';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.record_match WHERE record_id = '00000000-0000-0000-0000-0000000061e2'), 'a corrected number no longer points at the old mark';
  ASSERT (SELECT count(*) FROM watch.record_match) = 1, 'the other match stands';
END $$;
ROLLBACK;
\echo ALL 0061 TESTS PASSED
