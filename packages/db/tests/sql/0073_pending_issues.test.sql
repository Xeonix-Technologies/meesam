-- Tests for migration 0073: an account sees which publications of the registries it watches are still under review.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000073a1', 'owner_individual', '{"en": "Owner SeventyThree"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000073a2', 'owner_individual', '{"en": "No Marks SeventyThree"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000073f1', '00000000-0000-0000-0000-0000000073a1', '{"en": "SEVENTYTHREE"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000073e1', '00000000-0000-0000-0000-0000000073f1', id, '730100', '{"en": "Seventythree"}', 'existing', 'paid' FROM registry.registry WHERE code = 'QA';
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT '00000000-0000-0000-0000-0000000073e1', id, 'filed' FROM registry.registry WHERE code = 'QA';
DO $$ DECLARE v_src uuid; a uuid; b uuid; c uuid; g uuid; BEGIN
  SELECT s.id, s.registry_id INTO v_src, g FROM watch.publication_source s JOIN registry.registry r ON r.id = s.registry_id WHERE r.code = 'QA' AND s.stream = 'national_bulletin';
  INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) VALUES (v_src, 'T73-read', current_date - 10, 'k1') RETURNING id INTO a;
  INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) VALUES (v_src, 'T73-unread', current_date - 5, 'k2') RETURNING id INTO b;
  INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) VALUES (v_src, 'T73-done', current_date - 20, 'k3') RETURNING id INTO c;
  INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, verify_state) VALUES
    (a, g, current_date - 10, '1', '{1}', 'ai_extracted'), (a, g, current_date - 10, '2', '{1}', 'human_verified'), (c, g, current_date - 20, '3', '{1}', 'human_verified');
END $$;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000073a1', true);
DO $$ BEGIN
  ASSERT (SELECT array_agg(issue_no ORDER BY issue_no) FROM watch.fn_pending_issues() WHERE issue_no LIKE 'T73-%') = ARRAY['T73-read', 'T73-unread'], 'issues not yet read or not fully verified are shown; a fully verified one is not';
  ASSERT (SELECT marks = 2 AND waiting = 1 FROM watch.fn_pending_issues() WHERE issue_no = 'T73-read') AND (SELECT marks = 0 FROM watch.fn_pending_issues() WHERE issue_no = 'T73-unread'), 'with counts only';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000073a2', true);
DO $$ BEGIN ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_pending_issues() WHERE issue_no LIKE 'T73-%'), 'an account that watches nothing in that registry is shown nothing'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0073 TESTS PASSED
