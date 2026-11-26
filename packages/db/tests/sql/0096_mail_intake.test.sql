-- Tests for migration 0096: a file received by e-mail waits; only the lead decides; nothing else can enter or decide.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t96.lead', platform.fn_staff_invite('lead@x96.test', 'Lead Person', 'watch_lead')::text, false);
SELECT set_config('t96.rev', platform.fn_staff_invite('rev@x96.test', 'Rev', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x96.test', 'rev@x96.test');

SET LOCAL ROLE meesam_admin;
DO $$ DECLARE refused integer := 0; BEGIN
  ASSERT watch.fn_mail_intake_receive('gazette@office.example', 'Bulletin 12', 'b12.pdf', 5000, sha256('b12'), '_mail/aa/b12.pdf'), 'a file is entered';
  ASSERT NOT watch.fn_mail_intake_receive('gazette@office.example', 'Bulletin 12 again', 'b12.pdf', 5000, sha256('b12'), '_mail/bb/b12.pdf'), 'the same file still waiting is not entered twice';
  ASSERT watch.fn_mail_intake_receive('gazette@office.example', NULL, 'b13.pdf', 6000, sha256('b13'), '_mail/cc/b13.pdf'), 'another file is entered';
  BEGIN PERFORM watch.fn_mail_intake_receive('x@y.example', NULL, 'b.pdf', 10, sha256('q'), 'AE/national_bulletin/x.pdf'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 1, 'a waiting file is kept only under _mail/, never where publications are kept';
END $$;
RESET ROLE;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t96.rev'), true);
DO $$ DECLARE denied integer := 0; v uuid := (SELECT id FROM watch.mail_intake WHERE file_name = 'b12.pdf'); BEGIN
  ASSERT (SELECT count(*) FROM watch.mail_intake WHERE state = 'waiting') = 2, 'staff see the waiting files';
  BEGIN PERFORM watch.fn_mail_intake_decide(v, 'added', 'GB 2026-046'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN PERFORM watch.fn_mail_intake_receive('a@b.example', NULL, 'c.pdf', 10, sha256('c'), '_mail/dd/c.pdf'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 2, 'a reviewer decides nothing, and staff cannot enter a file as if it had arrived';
END $$;
SELECT set_config('meesam.user_id', current_setting('t96.lead'), true);
DO $$ DECLARE refused integer := 0; v uuid := (SELECT id FROM watch.mail_intake WHERE file_name = 'b12.pdf'); w uuid := (SELECT id FROM watch.mail_intake WHERE file_name = 'b13.pdf'); BEGIN
  PERFORM watch.fn_mail_intake_decide(v, 'added', 'GB 2026-046');
  ASSERT (SELECT state = 'added' AND added_as = 'GB 2026-046' AND decided_by = current_setting('t96.lead')::uuid FROM watch.mail_intake WHERE id = v), 'added, with who and as what';
  BEGIN PERFORM watch.fn_mail_intake_decide(v, 'discarded'); EXCEPTION WHEN no_data_found THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_mail_intake_decide(w, 'waiting'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 2, 'a decision is made once, and is added or discarded';
  PERFORM watch.fn_mail_intake_decide(w, 'discarded');
  ASSERT (SELECT state = 'discarded' AND added_as IS NULL FROM watch.mail_intake WHERE id = w), 'discarded';
  ASSERT (SELECT count(*) FROM watch.publication_issue i WHERE i.object_key LIKE '\_mail/%') = 0, 'a waiting file is never a publication';
END $$;
RESET ROLE;
SET LOCAL ROLE meesam_admin;
DO $$ BEGIN ASSERT watch.fn_mail_intake_receive('gazette@office.example', NULL, 'b12.pdf', 5000, sha256('b12'), '_mail/ee/b12.pdf'), 'a file decided earlier may arrive again'; END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ DECLARE denied integer := 0; BEGIN
  BEGIN PERFORM 1 FROM watch.mail_intake; EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN PERFORM watch.fn_mail_intake_receive('a@b.example', NULL, 'c.pdf', 10, sha256('c'), '_mail/dd/c.pdf'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 2, 'an account sees and enters nothing';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0096 TESTS PASSED
