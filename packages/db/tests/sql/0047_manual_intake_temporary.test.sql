-- Tests for migration 0047: a publication is added by hand only on a source switched to it, by the lead, once.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t47.lead', platform.fn_staff_invite('lead@x47.test', 'Lead Person', 'watch_lead')::text, false);
SELECT set_config('t47.rev', platform.fn_staff_invite('rev@x47.test', 'Rev', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x47.test', 'rev@x47.test');
CREATE TEMP TABLE _s AS SELECT s.id, g.code FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('GB', 'AE', 'SA') AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t47.lead'), true);
DO $$
DECLARE gb uuid := (SELECT id FROM _s WHERE code = 'GB'); ae uuid := (SELECT id FROM _s WHERE code = 'AE'); refused integer := 0; v uuid;
BEGIN
  -- a source that is not switched to "by hand" takes no file from anyone (the rule of 7–8 Nov still holds there)
  BEGIN PERFORM watch.fn_manual_add(ae, '355', current_date, 'k', sha256('a'), 10, 'rar', 'f.rar'); EXCEPTION WHEN insufficient_privilege THEN refused := refused + 1; END;
  -- re-use must be confirmed before anything is collected, by hand or not
  BEGIN PERFORM watch.fn_source_manual(gb, true, 'site refuses the fetcher'); EXCEPTION WHEN no_data_found THEN refused := refused + 1; END;
  ASSERT refused = 2, 'no file on an automatic source; no by-hand collection before re-use is confirmed';
  PERFORM watch.fn_source_confirm_reuse(gb, 'Open Government Licence');
  BEGIN PERFORM watch.fn_source_manual(gb, true, ' '); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  ASSERT refused = 3, 'a reason is required';
  PERFORM watch.fn_source_manual(gb, true, 'ipo.gov.uk answers 403 to the fetcher');
  ASSERT (SELECT manual_intake AND paused AND manual_by = current_setting('t47.lead')::uuid FROM watch.publication_source WHERE id = gb), 'by hand, and the fetcher stops asking';
  ASSERT watch.fn_manual_due_on(gb) = current_date, 'nothing held: due at once';

  BEGIN PERFORM watch.fn_manual_add(gb, '2026-046', NULL, 'k', sha256('j46'), 10, 'pdf', 'jnl.pdf'); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_manual_add(gb, '2026-046', current_date + 5, 'k', sha256('j46'), 10, 'pdf', 'jnl.pdf'); EXCEPTION WHEN datetime_field_overflow THEN refused := refused + 1; END;
  ASSERT refused = 5, 'the issue date is required and cannot be in the future';
  v := watch.fn_manual_add(gb, '2026-046', current_date - 6, 'GB/national_bulletin/2026-046_aa.pdf', sha256('j46'), 16000000, 'pdf', 'jnl.pdf');
  ASSERT (SELECT intake = 'manual' AND added_by = current_setting('t47.lead')::uuid AND object_key IS NOT NULL FROM watch.publication_issue WHERE id = v), 'held, marked as added by hand, with who';
  ASSERT (SELECT detail ->> 'manual' = 'true' AND detail ->> 'by' = 'Lead Person' FROM watch.fetch_run WHERE issue_id = v), 'the run says so';
  ASSERT watch.fn_manual_due_on(gb) = current_date + 1, 'the next one is expected a week after this issue';
  BEGIN PERFORM watch.fn_manual_add(gb, '2026-046', current_date - 6, 'k2', sha256('other'), 10, 'pdf', 'x.pdf'); EXCEPTION WHEN unique_violation THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_manual_add(gb, '2026-047', current_date, 'k3', sha256('j46'), 10, 'pdf', 'x.pdf'); EXCEPTION WHEN unique_violation THEN refused := refused + 1; END;
  ASSERT refused = 7, 'an issue is held once, and a file is held once';
END $$;
SELECT set_config('meesam.user_id', current_setting('t47.rev'), true);
DO $$ DECLARE denied integer := 0; gb uuid := (SELECT id FROM _s WHERE code = 'GB'); BEGIN
  BEGIN PERFORM watch.fn_manual_add(gb, '2026-047', current_date, 'k', sha256('z'), 10, 'pdf', 'x.pdf'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN PERFORM watch.fn_source_manual(gb, false); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  BEGIN INSERT INTO watch.publication_issue (source_id, issue_no) VALUES (gb, 'x'); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 3, 'only the watch operations lead adds a file or switches the source; nobody writes the table directly';
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT count(*) FROM platform.audit_event WHERE schema_name = 'watch' AND table_name = 'publication_issue' AND user_id = current_setting('t47.lead')::uuid) = 1, 'the added issue is audited to the person'; END $$;

-- reminders: nothing while the next issue is not due; one per lead when it is; not again for three days
SET LOCAL ROLE meesam_worker;
DO $$ DECLARE gb uuid := (SELECT id FROM _s WHERE code = 'GB'); BEGIN
  ASSERT (SELECT count(*) FROM watch.fn_manual_reminders_take() WHERE registry_code = 'GB') = 0, 'not due yet';
END $$;
RESET ROLE;
UPDATE watch.publication_schedule SET expected_next = current_date - 1 WHERE source_id = (SELECT id FROM _s WHERE code = 'GB');
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM watch.fn_manual_reminders_take() WHERE registry_code = 'GB' AND email = 'lead@x47.test' AND last_issue = '2026-046' AND where_from = 'https://www.ipo.gov.uk/t-tmj.htm') = 1, 'the lead is reminded, with where to find it';
  ASSERT (SELECT count(*) FROM watch.fn_manual_reminders_take()) = 0, 'not twice';
  ASSERT NOT EXISTS (SELECT 1 FROM watch.fn_fetch_due() WHERE registry_code = 'GB'), 'the automatic fetcher does not ask a by-hand source';
END $$;
RESET ROLE;
-- back to automatic
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t47.lead'), true);
DO $$ DECLARE gb uuid := (SELECT id FROM _s WHERE code = 'GB'); refused boolean := false; BEGIN
  PERFORM watch.fn_source_manual(gb, false);
  BEGIN PERFORM watch.fn_manual_add(gb, '2026-047', current_date, 'k', sha256('n'), 10, 'pdf', 'x.pdf'); EXCEPTION WHEN insufficient_privilege THEN refused := true; END;
  ASSERT refused AND (SELECT paused FROM watch.publication_source WHERE id = gb), 'switched off: no more files by hand; the fetcher stays paused until resumed';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0047 TESTS PASSED
