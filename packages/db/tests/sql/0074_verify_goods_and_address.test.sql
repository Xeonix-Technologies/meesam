-- Tests for migration 0074: the reviewer corrects the goods and the applicant's address; what was read is kept.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t74.rev', platform.fn_staff_invite('rev@x74.test', 'Rev SeventyFour', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email = 'rev@x74.test';
CREATE TEMP TABLE _i AS
  WITH q AS (SELECT s.id, s.registry_id FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'QA' AND s.stream = 'national_bulletin'),
       a AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) SELECT id, 'T74-A', current_date - 2, 'QA/national_bulletin/T74-A_x.pdf' FROM q RETURNING id),
       u AS (INSERT INTO watch.read_run (issue_id, model, token_cap) SELECT id, 'claude-sonnet-5-5', 100000 FROM a RETURNING id)
  SELECT a.id AS issue, u.id AS run FROM a, u;
GRANT SELECT ON _i TO PUBLIC;
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  PERFORM watch.fn_read_mark_store((SELECT run FROM _i), '{"page":17,"application_no":"740001","classes":[3],"applicant_name":"Owner","goods":"soap; perfume …","applicant_address":"Shop AL12JP, Dubai"}');
  PERFORM watch.fn_read_mark_store((SELECT run FROM _i), '{"page":18,"application_no":"740002","classes":[3],"goods":"soap"}');
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t74.rev'), true);
DO $$ DECLARE i uuid := (SELECT issue FROM _i); c text[]; BEGIN
  c := watch.fn_mark_verify(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '740001'),
         jsonb_build_object('goods', E'soap; perfume;\ncosmetics', 'applicant_address', 'Shop JP12AL, Dubai', 'applicant_name', 'Owner'));
  ASSERT c = ARRAY['goods', 'applicant_address'], 'the goods and the address are corrected and named: ' || c::text;
  c := watch.fn_mark_verify(i, (SELECT id FROM watch.published_mark WHERE issue_id = i AND application_no = '740002'), '{"goods":" soap "}');
  ASSERT c = '{}', 'goods left as read are not a correction';
END $$;
RESET ROLE;
DO $$ DECLARE m watch.published_mark; BEGIN
  SELECT x.* INTO m FROM watch.published_mark x WHERE x.application_no = '740001' AND x.issue_id = (SELECT issue FROM _i);
  ASSERT m.verify_state = 'human_verified' AND m.extraction ->> 'goods' = E'soap; perfume;\ncosmetics' AND m.extraction ->> 'applicant_address' = 'Shop JP12AL, Dubai', 'the corrected texts are stored, line breaks kept';
  ASSERT m.extraction -> 'read' ->> 'goods' = 'soap; perfume …' AND m.extraction -> 'read' ->> 'applicant_address' = 'Shop AL12JP, Dubai', 'what the reader gave is kept beside them';
END $$;
ROLLBACK;
\echo ALL 0074 TESTS PASSED
