-- Tests for migration 0069: the first comparison engine (text family), class gate, bands, alerts per account, and what holds an alert back.
BEGIN;
SET client_min_messages = warning;
-- scoring
DO $$ DECLARE t record; w jsonb := (SELECT rules -> 'weights' FROM watch.engine_config WHERE version = 1); BEGIN
  ASSERT watch.fn_lev('kitten', 'sitting') = 3 AND watch.fn_lev('', 'abc') = 3 AND watch.fn_lev('same', 'same') = 0, 'edit distance';
  ASSERT watch.fn_strip_entity('oryx trading co llc') = 'oryx trading' AND watch.fn_strip_entity('llc') = 'llc' AND watch.fn_strip_entity('شركه المها ذ م م') = 'المها', 'words that only state the legal form are stripped; a name made only of them is kept';
  ASSERT watch.fn_contained('nova', 'nova star') AND NOT watch.fn_contained('nova', 'nova') AND NOT watch.fn_contained('no', 'no way') AND NOT watch.fn_contained('nova', 'novastar'), 'one name contained in the other, by whole words';
  SELECT * INTO t FROM watch.fn_text_match('{"en":"meesam"}', '{"en":"meesam"}', w);
  ASSERT t.best = 1 AND t.reasons @> '[{"code":"same_text","script":"en"}]', 'the same name scores 1';
  SELECT * INTO t FROM watch.fn_text_match('{"en":"meesam"}', '{"en":"maysam"}', w);
  ASSERT t.score_phonetic = 1 AND t.best = 0.9 AND t.reasons @> '[{"code":"sounds_alike","script":"en"}]', 'names that sound alike in the same script: ' || t.best;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"meesam"}', '{"ar":"ميسم"}', w);
  ASSERT t.score_cross = 1 AND t.best = 0.85 AND t.reasons @> '[{"code":"sounds_alike_cross"}]', 'Arabic against Latin by sound: ' || t.best;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"nova"}', '{"en":"nova star"}', w);
  ASSERT t.best = 0.85 AND t.reasons @> '[{"code":"contained","script":"en"}]', 'one name contained in the other';
  SELECT * INTO t FROM watch.fn_text_match('{"en":"oryx"}', '{"en":"zebra house"}', w);
  ASSERT t.best < 0.55, 'unlike names stay under the floor: ' || t.best;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"oryx co llc"}', '{"en":"oryx"}', w);
  ASSERT t.best = 1, 'the legal form does not make two names differ';
END $$;

INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000069a1', 'owner_individual', '{"en": "Falcon Holdings LLC"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000069a2', 'agency_office', '{"en": "Agency SixtyNine"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000069f1', '00000000-0000-0000-0000-0000000069a1', '{"en": "MEESAM"}', 'word'),
  ('00000000-0000-0000-0000-0000000069f2', '00000000-0000-0000-0000-0000000069a1', '{"en": "CLOSED"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state, terminal)
  SELECT '00000000-0000-0000-0000-0000000069e1'::uuid, '00000000-0000-0000-0000-0000000069f1'::uuid, id, '500100', '{"en": "Meesam", "ar": "ميسم"}'::jsonb, 'existing'::core.entry_mode, 'paid'::core.paid_state, false FROM registry.registry WHERE code = 'AE'
  UNION ALL
  SELECT '00000000-0000-0000-0000-0000000069e2'::uuid, '00000000-0000-0000-0000-0000000069f2'::uuid, id, '500200', '{"en": "Meesam"}'::jsonb, 'existing'::core.entry_mode, 'paid'::core.paid_state, true FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT r.id, r.registry_id, 'filed' FROM core.record r WHERE r.id IN ('00000000-0000-0000-0000-0000000069e1', '00000000-0000-0000-0000-0000000069e2');
INSERT INTO core.record_class (record_id, nice_class_id) SELECT r.id, n.id FROM core.record r, registry.nice_class n WHERE r.id IN ('00000000-0000-0000-0000-0000000069e1', '00000000-0000-0000-0000-0000000069e2') AND n.number IN (9, 42);
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by) VALUES ('00000000-0000-0000-0000-0000000069c1', '00000000-0000-0000-0000-0000000069a1', '00000000-0000-0000-0000-0000000069a2', 'accepted', 'owner');
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000069c1', '00000000-0000-0000-0000-0000000069e1');
DO $$ BEGIN
  ASSERT core.fn_record_watched('00000000-0000-0000-0000-0000000069e1') AND NOT core.fn_record_watched('00000000-0000-0000-0000-0000000069e2'), 'a paid open trademark is watched; a closed one is not';
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_record' AND payload ->> 'record_id' = '00000000-0000-0000-0000-0000000069e1' AND status = 'queued') = 1, 'a new or changed trademark is queued once for comparing with what is already published';
END $$;

CREATE TEMP TABLE _i AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T69', current_date - 3 FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, NULL, true FROM _i
  ON CONFLICT (registry_id) DO UPDATE SET may_store = true, may_show = NULL, may_derive = true;
-- b1 sounds alike, same class; b2 same name, other class; b3 unlike; b4 same name, same class, the owner's own filing; b5 contained, same class; b6 unverified
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state)
  SELECT v.id::uuid, issue_id, registry_id, current_date - 3, v.no, v.txt::jsonb, v.cls::smallint[], v.who, v.st::watch.verify_state FROM _i,
  (VALUES ('00000000-0000-0000-0000-0000000069b1', '900001', '{"en": "MAYSAM"}', '{42}', 'Other Co', 'human_verified'),
          ('00000000-0000-0000-0000-0000000069b2', '900002', '{"en": "MEESAM"}', '{25}', 'Other Co', 'human_verified'),
          ('00000000-0000-0000-0000-0000000069b3', '900003', '{"en": "ZEBRA HOUSE"}', '{42}', 'Other Co', 'human_verified'),
          ('00000000-0000-0000-0000-0000000069b4', '900004', '{"en": "MEESAM"}', '{9}', 'Falcon Holdings', 'human_verified'),
          ('00000000-0000-0000-0000-0000000069b5', '900005', '{"en": "MEESAM PAY"}', '{9}', 'Other Co', 'human_verified'),
          ('00000000-0000-0000-0000-0000000069b6', '900006', '{"en": "MEESAM"}', '{9}', 'Other Co', 'ai_extracted')) AS v(id, no, txt, cls, who, st);
DO $$ DECLARE n integer; g uuid := (SELECT registry_id FROM _i); d date := current_date - 3; BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare' AND status = 'queued') = 5, 'each verified mark is queued for comparing; the unverified one is not';
  -- the worker's work, with "show" not yet allowed in the re-use register
  n := watch.fn_compare(g, d, '00000000-0000-0000-0000-0000000069b1') + watch.fn_compare(g, d, '00000000-0000-0000-0000-0000000069b2') + watch.fn_compare(g, d, '00000000-0000-0000-0000-0000000069b3')
     + watch.fn_compare(g, d, '00000000-0000-0000-0000-0000000069b4') + watch.fn_compare(g, d, '00000000-0000-0000-0000-0000000069b5') + watch.fn_compare(g, d, '00000000-0000-0000-0000-0000000069b6');
  ASSERT n = 0 AND NOT EXISTS (SELECT 1 FROM watch.alert), 'no alert is raised while the re-use register does not allow showing the registry''s data';
  ASSERT (SELECT count(*) FROM watch.candidate) = 4 AND (SELECT bool_and(explanation ->> 'held' = 'reuse_show') FROM watch.candidate), 'the matches are kept, marked as held back';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.candidate WHERE record_id = '00000000-0000-0000-0000-0000000069e2'), 'a closed trademark is compared with nothing';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.candidate WHERE published_mark_id IN ('00000000-0000-0000-0000-0000000069b3', '00000000-0000-0000-0000-0000000069b6')), 'an unlike name and an unverified mark give no match';
END $$;
-- "show" is allowed: the registry's marks are queued again
UPDATE watch.reuse_register SET may_show = true WHERE registry_id = (SELECT registry_id FROM _i);
DO $$ DECLARE n integer; c watch.candidate; BEGIN
  ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_registry' AND status = 'queued') = 1, 'allowing "show" queues the registry''s marks again';
  n := watch.fn_compare_registry((SELECT registry_id FROM _i));
  ASSERT n = 4, 'two matches alert, each for the owner and for the appointed agency: ' || n;
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000069b1';
  ASSERT c.score = 0.9 AND c.class_overlap = '{42}' AND c.explanation ->> 'band' = 'high' AND c.explanation ->> 'class' = 'same', 'sounds alike in the same class is High: ' || c.score;
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000069b5';
  ASSERT c.score = 0.85 AND c.explanation ->> 'band' = 'high', 'contained in the other, same class';
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000069b2';
  ASSERT c.score = 1 AND c.class_overlap = '{}' AND c.explanation ->> 'class' = 'outside' AND NOT EXISTS (SELECT 1 FROM watch.alert WHERE candidate_id = c.id), 'the same name outside the classes is kept as a match and raises no alert';
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000069b4';
  ASSERT (c.explanation ->> 'own')::boolean AND NOT EXISTS (SELECT 1 FROM watch.alert WHERE candidate_id = c.id) AND EXISTS (SELECT 1 FROM watch.own_filing_suppression WHERE published_mark_id = c.published_mark_id), 'the owner''s own publication is not an alert';
  ASSERT (SELECT count(DISTINCT account_id) FROM watch.alert) = 2 AND (SELECT bool_and(risk_band = 'high' AND status = 'new' AND opposition_deadline = current_date - 3 + 30) FROM watch.alert), 'one alert per account, with the deadline from the verified UAE period';
  ASSERT (SELECT count(*) FROM platform.notification WHERE kind = 'alert_new') = 4, 'each alert is notified in the app';
  n := watch.fn_compare_registry((SELECT registry_id FROM _i));
  ASSERT n = 0 AND (SELECT count(*) FROM watch.alert) = 4 AND (SELECT count(*) FROM watch.candidate) = 4, 'comparing again raises nothing twice';
  n := watch.fn_compare_record('00000000-0000-0000-0000-0000000069e1');
  ASSERT n = 0, 'the backfill for a trademark finds the same marks and raises nothing twice';
END $$;
-- related classes come from the registry profile's own table
UPDATE registry.registry_profile p SET rules = p.rules || '{"related_classes": {"42": [35]}}' WHERE p.id = (SELECT (registry.fn_current_profile((SELECT registry_id FROM _i))).id);
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state)
  SELECT '00000000-0000-0000-0000-0000000069b7', issue_id, registry_id, current_date - 3, '900007', '{"en": "MEESAM"}', '{35}', 'Other Co', 'human_verified' FROM _i;
DO $$ DECLARE c watch.candidate; BEGIN
  PERFORM watch.fn_compare((SELECT registry_id FROM _i), current_date - 3, '00000000-0000-0000-0000-0000000069b7');
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000069b7';
  ASSERT c.score = 0.75 AND c.explanation ->> 'class' = 'related' AND c.explanation ->> 'band' = 'medium' AND (SELECT count(*) FROM watch.alert WHERE candidate_id = c.id AND risk_band = 'medium') = 2, 'the same name in a related class is Medium (ruling R6)';
END $$;

-- an account acts on its own alert only
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000069a1', true);
DO $$ DECLARE v uuid; other uuid; refused integer := 0; BEGIN
  ASSERT (SELECT count(*) FROM watch.alert) = 3 AND (SELECT count(*) FROM watch.published_mark) = 3, 'an account sees its own alerts and the published marks behind them, nothing else';
  SELECT id INTO v FROM watch.alert ORDER BY created_at, id LIMIT 1;
  BEGIN UPDATE watch.alert SET status = 'dismissed' WHERE id = v; EXCEPTION WHEN insufficient_privilege THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_alert_set(v, 'dismissed'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 2, 'an alert is changed only through its function, and dismissing needs a reason';
  PERFORM watch.fn_alert_set(v, 'dismissed', 'different_goods');
  ASSERT (SELECT status = 'dismissed' AND dismiss_reason = 'different_goods' FROM watch.alert WHERE id = v), 'dismissed with its reason';
  PERFORM watch.fn_alert_set(v, 'reviewing');
  ASSERT (SELECT status = 'reviewing' AND dismiss_reason IS NULL FROM watch.alert WHERE id = v), 'marked reviewed';
END $$;
RESET ROLE;
DO $$ DECLARE v uuid; BEGIN
  ASSERT (SELECT count(*) FROM watch.alert WHERE account_id = '00000000-0000-0000-0000-0000000069a2' AND status = 'new') = 3, 'the other account''s alerts are untouched: never shared between accounts';
  -- no verified period: the deadline is entered by hand before the alert can be marked reviewed
  SELECT id INTO v FROM watch.alert WHERE account_id = '00000000-0000-0000-0000-0000000069a2' LIMIT 1;
  UPDATE watch.alert SET opposition_deadline = NULL WHERE id = v;
  PERFORM set_config('t69.v', v::text, false);
END $$;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000069a2', true);
DO $$ DECLARE v uuid := current_setting('t69.v')::uuid; BEGIN
  BEGIN PERFORM watch.fn_alert_set(v, 'reviewing'); RAISE EXCEPTION 'reviewed without a deadline'; EXCEPTION WHEN null_value_not_allowed THEN NULL; END;
  PERFORM watch.fn_alert_set(v, 'reviewing', NULL, current_date + 20);
  ASSERT (SELECT status = 'reviewing' AND opposition_deadline = current_date + 20 FROM watch.alert WHERE id = v), 'the deadline entered by hand is kept';
  BEGIN PERFORM watch.fn_alert_set((SELECT id FROM watch.alert WHERE false), 'reviewing'); EXCEPTION WHEN no_data_found THEN NULL; END;
END $$;
RESET ROLE;
-- e-mails: new alerts once per user of the account, then a reminder when the deadline is near and the alert is still new
INSERT INTO core.app_user (account_id, email, name, status, role) VALUES ('00000000-0000-0000-0000-0000000069a1', 'owner@x69.test', 'Owner SixtyNine', 'active', 'company_admin');
DO $$ DECLARE r record; n integer := 0; BEGIN
  FOR r IN SELECT * FROM watch.fn_alert_mails_take() LOOP n := n + 1; ASSERT r.kind = 'new' AND r.email = 'owner@x69.test' AND r.alerts = 3 AND r.high = 2, 'new alerts are mailed to the account''s user: ' || r.alerts || '/' || r.high; END LOOP;
  ASSERT n = 1, 'one e-mail per user (the agency has no active user here): ' || n;
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_alert_mails_take()), 'nothing is mailed twice';
  UPDATE watch.alert SET opposition_deadline = current_date + 9 WHERE account_id = '00000000-0000-0000-0000-0000000069a1' AND status = 'new';
  SELECT count(*) INTO n FROM watch.fn_alert_mails_take() x WHERE x.kind = 'reminder' AND x.days_left = 9;
  ASSERT n = 1, 'a reminder when ten days or fewer remain and the alert is still new';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_alert_mails_take()), 'the same reminder is not sent twice';
  UPDATE watch.alert SET opposition_deadline = current_date + 2 WHERE account_id = '00000000-0000-0000-0000-0000000069a1' AND status = 'new';
  SELECT count(*) INTO n FROM watch.fn_alert_mails_take() x WHERE x.kind = 'reminder';
  ASSERT n = 1 AND NOT EXISTS (SELECT 1 FROM watch.fn_alert_mails_take()), 'a final reminder at three days, then no more';
END $$;
ROLLBACK;
\echo ALL 0069 TESTS PASSED
