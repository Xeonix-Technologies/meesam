-- Tests for migration 0083: a weak likeness of sound alone is Low; a match always has its reason; the alert e-mail names the marks.
BEGIN;
SET client_min_messages = warning;
DO $$ DECLARE t record; w jsonb := (SELECT rules FROM watch.engine_config ORDER BY version DESC LIMIT 1); BEGIN
  ASSERT (w ->> 'sound_alert_min')::numeric = 0.8 AND (w ->> 'spelling_alert_min')::numeric = 0.7 AND (w ->> 'weak_cap')::numeric = 0.59 AND w ? 'weights' AND w ? 'backfill_days', 'the figures are settings, added to the settings in force';
  SELECT * INTO t FROM watch.fn_text_match('{"en":"oro selekt"}', '{"en":"er pelet"}', w);
  ASSERT t.best = 0.59 AND jsonb_array_length(t.reasons) = 1 AND t.reasons -> 0 ->> 'code' = 'similar_text' AND (t.reasons -> 0 ->> 'score')::numeric = 0.6,
    'the Founder''s case: a weak likeness of spelling alone is Low, and says what it rests on: ' || t.best || ' ' || t.reasons;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"meesam"}', '{"en":"meesan"}', w);
  ASSERT t.best > 0.8, 'one letter apart in six still alerts: ' || t.best;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"meesam"}', '{"en":"maysam"}', w);
  ASSERT t.best = 0.9, 'two names that sound the same still alert: ' || t.best;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"oro selekt"}', '{"en":"oro isso"}', w);
  ASSERT t.best = 0.8 AND t.reasons @> '[{"code":"shared_first_word"}]', 'a shared first word is untouched';
  -- Founder ruling 22 Nov 2026: "d'oro" is read as carrying "oro" (the apostrophe separates words when a name is normalised)
  SELECT * INTO t FROM watch.fn_text_match('{"en":"oro selekt"}', jsonb_build_object('en', watch.fn_normalise_latin('argos d''oro olive')), w);
  ASSERT t.best = 0.7 AND t.reasons @> '[{"code":"shared_word","word":"oro"}]', '"argos d''oro olive" against "oro selekt": a shared word, Medium: ' || t.best;
  SELECT * INTO t FROM watch.fn_text_match('{"en":"meesam"}', '{"en":"seesaw"}', w);
  ASSERT jsonb_array_length(t.reasons) >= 1, 'a match is never left without its reason';
END $$;
-- the e-mail names the marks
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000083a1', 'owner_individual', '{"en": "Owner EightyThree"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (account_id, email, name, role, status, locale) VALUES ('00000000-0000-0000-0000-0000000083a1', 'o83@x83.test', 'Owner 83', 'company_admin', 'active', 'en');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000083f1', '00000000-0000-0000-0000-0000000083a1', '{"en": "oro selekt"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000083e1'::uuid, '00000000-0000-0000-0000-0000000083f1'::uuid, id, '830100', '{"en": "oro selekt"}'::jsonb, 'existing', 'free_loaded' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_class (record_id, nice_class_id) SELECT '00000000-0000-0000-0000-0000000083e1', id FROM registry.nice_class WHERE number = 35;
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000083e1', id, 'watch_only' FROM registry.registry WHERE code = 'TR';
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T83', current_date - 10 FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, true, true FROM _t
  ON CONFLICT (registry_id) DO UPDATE SET may_store = true, may_show = true, may_derive = true;
UPDATE watch.alert SET mailed_at = now() WHERE mailed_at IS NULL;
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state)
  SELECT v.id::uuid, issue_id, registry_id, current_date - 10, v.no, v.txt::jsonb, v.cls::smallint[], 'Other Co', 'waived' FROM _t,
  (VALUES ('00000000-0000-0000-0000-0000000083b1', '2026/887250', '{"en": "oro vicenza jewellery"}', '{14,35}'),
          ('00000000-0000-0000-0000-0000000083b2', '2026/562790', '{"en": "er pelet"}', '{4}'),
          ('00000000-0000-0000-0000-0000000083b3', '2026/069330', '{"en": "oro"}', '{32}')) AS v(id, no, txt, cls);
DO $$ DECLARE m record; c watch.candidate; BEGIN
  ASSERT watch.fn_compare_issue((SELECT issue_id FROM _t)) = 2, 'two alerts; the weak one raises none';
  SELECT * INTO c FROM watch.candidate WHERE published_mark_id = '00000000-0000-0000-0000-0000000083b2';
  ASSERT c.explanation ->> 'band' = 'low' AND NOT EXISTS (SELECT 1 FROM watch.alert WHERE candidate_id = c.id), '"er pelet" is kept as Low, listed only';
  -- an alert raised for it under the earlier rule, not acted on, is withdrawn
  INSERT INTO watch.alert (candidate_id, record_id, registry_id, account_id, risk_band) VALUES (c.id, c.record_id, (SELECT registry_id FROM _t), '00000000-0000-0000-0000-0000000083a1', 'medium');
  ASSERT watch.fn_alerts_settle() = 1, 'one alert withdrawn';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.alert WHERE candidate_id = c.id), 'withdrawn';
  SELECT * INTO m FROM watch.fn_alert_mails_take() x WHERE x.email = 'o83@x83.test';
  ASSERT m.alerts = 2 AND m.high = 2 AND jsonb_array_length(m.items) = 2, 'one e-mail for the two alerts, with the marks: ' || m.items;
  ASSERT m.items -> 0 ->> 'mark' = 'oro' AND (m.items -> 0 ->> 'score')::int = 85 AND m.items -> 0 ->> 'registry' = 'TR' AND NOT (m.items -> 0 ->> 'same_class')::boolean, 'the strongest first, with registry, likeness and class';
  ASSERT m.items -> 1 ->> 'mark' = 'oro vicenza jewellery' AND (m.items -> 1 ->> 'same_class')::boolean AND m.items -> 1 ->> 'band' = 'high', 'the second names its shared class';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_alert_mails_take() x WHERE x.email = 'o83@x83.test'), 'sent once';
END $$;
ROLLBACK;
\echo ALL 0083 TESTS PASSED
