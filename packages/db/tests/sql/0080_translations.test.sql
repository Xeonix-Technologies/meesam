-- Tests for migration 0080: who asks for a translation, where it is kept, and that an alert asks for one per language of the account's users.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t80.rev', platform.fn_staff_invite('rev@x80.test', 'Rev Eighty', 'publication_reviewer')::text, false);
SELECT set_config('t80.adm', platform.fn_staff_invite('adm@x80.test', 'Adm Eighty', 'system_admin')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('rev@x80.test', 'adm@x80.test');
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000080a1', 'owner_individual', '{"en": "Owner Eighty"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (account_id, email, name, role, status, locale) VALUES
  ('00000000-0000-0000-0000-0000000080a1', 'en@x80.test', 'En', 'company_admin', 'active', 'en'), ('00000000-0000-0000-0000-0000000080a1', 'ar@x80.test', 'Ar', 'tm_manager', 'active', 'ar');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000080f1', '00000000-0000-0000-0000-0000000080a1', '{"en": "EIGHTY"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000080e1', '00000000-0000-0000-0000-0000000080f1', id, '800100', '{"en": "Eighty"}', 'existing', 'paid' FROM registry.registry WHERE code = 'TR';
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000080e1', id, 'filed' FROM registry.registry WHERE code = 'TR';
CREATE TEMP TABLE _i AS
  WITH s AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'TR' AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on) SELECT id, 'T80', current_date - 3 FROM s RETURNING id)
  SELECT i.id AS issue_id, s.registry_id FROM i, s;
GRANT SELECT ON _i TO PUBLIC;
INSERT INTO watch.reuse_register (registry_id, may_store, may_show, may_derive) SELECT registry_id, true, true, true FROM _i ON CONFLICT (registry_id) DO UPDATE SET may_show = true, may_derive = true;
INSERT INTO watch.published_mark (id, issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, verify_state, extraction)
  SELECT '00000000-0000-0000-0000-0000000080b1', issue_id, registry_id, current_date - 3, '2026/1', '{"en": "EIGHTY"}', '{32}', 'Öteki Şirket', 'human_verified', '{"goods": "Biralar"}' FROM _i;
DELETE FROM platform.job WHERE kind = 'watch.translate';
DO $$ BEGIN
  ASSERT watch.fn_compare((SELECT registry_id FROM _i), current_date - 3, '00000000-0000-0000-0000-0000000080b1') = 1, 'the alert is raised';
  ASSERT (SELECT array_agg(payload ->> 'lang' ORDER BY payload ->> 'lang') FROM platform.job WHERE kind = 'watch.translate' AND status = 'queued') = ARRAY['ar', 'en'], 'the published mark is queued for translation into each language of the account''s users';
END $$;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  PERFORM watch.fn_translation_store((SELECT issue_id FROM _i), '00000000-0000-0000-0000-0000000080b1', 'en', '{"goods": "Beers", "applicant_name": "Oteki Company"}');
  PERFORM watch.fn_translation_store((SELECT issue_id FROM _i), '00000000-0000-0000-0000-0000000080b1', 'ar', '{"goods": "بيرة"}');
END $$;
RESET ROLE;
DO $$ DECLARE m watch.published_mark; BEGIN
  SELECT * INTO m FROM watch.published_mark WHERE id = '00000000-0000-0000-0000-0000000080b1';
  ASSERT m.extraction #>> '{t,en,goods}' = 'Beers' AND m.extraction #>> '{t,ar,goods}' = 'بيرة' AND m.extraction #>> '{t,en,at}' IS NOT NULL, 'each language is kept beside the mark';
  ASSERT m.extraction ->> 'goods' = 'Biralar' AND m.applicant_name = 'Öteki Şirket' AND m.mark_text = '{"en": "EIGHTY"}', 'the registry''s own text and the mark''s wording are untouched';
END $$;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t80.adm'), true);
DO $$ BEGIN
  BEGIN PERFORM watch.fn_translation_request((SELECT issue_id FROM _i), '00000000-0000-0000-0000-0000000080b1', 'en'); RAISE EXCEPTION 'not a reviewer'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT set_config('meesam.user_id', current_setting('t80.rev'), true);
DO $$ BEGIN
  BEGIN PERFORM watch.fn_translation_request((SELECT issue_id FROM _i), '00000000-0000-0000-0000-0000000080b1', 'English'); RAISE EXCEPTION 'bad code'; EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
  PERFORM watch.fn_translation_request((SELECT issue_id FROM _i), '00000000-0000-0000-0000-0000000080b1', 'fr');
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.translate' AND payload ->> 'lang' = 'fr') = 1, 'a reviewer asks for a translation of one mark'; END $$;
ROLLBACK;
\echo ALL 0080 TESTS PASSED
