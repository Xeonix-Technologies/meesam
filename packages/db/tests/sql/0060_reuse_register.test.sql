-- Tests for migration 0060: the re-use register, and the gate that reads it.
BEGIN;
SET client_min_messages = warning;
SELECT set_config('t60.lead', platform.fn_staff_invite('lead@x60.test', 'Lead Sixty', 'watch_lead')::text, false);
SELECT set_config('t60.rev', platform.fn_staff_invite('rev@x60.test', 'Rev Sixty', 'publication_reviewer')::text, false);
UPDATE core.app_user SET status = 'active' WHERE email IN ('lead@x60.test', 'rev@x60.test');
CREATE TEMP TABLE _s AS SELECT s.id, s.registry_id, g.code FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('AE', 'GB', 'BH') AND s.stream = 'national_bulletin';
GRANT SELECT ON _s TO PUBLIC;

DO $$ BEGIN
  ASSERT (SELECT may_store AND terms IS NOT NULL AND may_train IS NULL FROM watch.reuse_register WHERE registry_id = (SELECT registry_id FROM _s WHERE code = 'AE')), 'the UAE basis already on record is carried into the register; uses not yet read stay unknown';
  ASSERT (SELECT may_store IS NULL AND terms IS NOT NULL FROM watch.reuse_register WHERE registry_id = (SELECT registry_id FROM _s WHERE code = 'GB')), 'terms noted for a source that was never switched on are carried over, with storing not yet confirmed';
END $$;

SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t60.rev'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM watch.fn_reuse_set((SELECT registry_id FROM _s WHERE code = 'GB'), 'x', NULL, NULL, true, NULL, NULL, NULL, NULL, NULL); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a reviewer cannot write the register';
END $$;
SELECT set_config('meesam.user_id', current_setting('t60.lead'), true);
DO $$ DECLARE refused integer := 0; gb uuid := (SELECT registry_id FROM _s WHERE code = 'GB'); BEGIN
  BEGIN PERFORM watch.fn_reuse_set(gb, 'x', 'ftp://nope', NULL, true, NULL, NULL, NULL, NULL, NULL); EXCEPTION WHEN invalid_parameter_value THEN refused := refused + 1; END;
  BEGIN PERFORM watch.fn_reuse_set(gb, 'x', NULL, current_date + 1, true, NULL, NULL, NULL, NULL, NULL); EXCEPTION WHEN datetime_field_overflow THEN refused := refused + 1; END;
  ASSERT refused = 2, 'a link must be a web address and the date read cannot be in the future';
  -- confirming re-use for a source writes the register
  PERFORM watch.fn_source_confirm_reuse((SELECT id FROM _s WHERE code = 'GB'), 'Open Government Licence v3.0');
  ASSERT (SELECT may_store AND terms IS NOT NULL AND read_on = current_date FROM watch.reuse_register WHERE registry_id = gb), 'confirmation is entered in the register';
  -- the lead completes the row
  PERFORM watch.fn_reuse_set(gb, 'Open Government Licence v3.0', 'https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/', current_date, true, true, true, NULL, false, 'contact not covered');
  ASSERT (SELECT may_show AND may_derive AND may_train IS NULL AND may_contact IS FALSE AND updated_by = current_setting('t60.lead')::uuid FROM watch.reuse_register WHERE registry_id = gb), 'each use is recorded: yes, no, or not yet read';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE schema_name = 'watch' AND table_name = 'reuse_register' AND user_id = current_setting('t60.lead')::uuid) >= 2, 'register changes are audited to the person';
END $$;

-- the gate: storing not allowed
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t60.lead'), true);
DO $$ DECLARE gb uuid := (SELECT registry_id FROM _s WHERE code = 'GB'); src uuid := (SELECT id FROM _s WHERE code = 'GB'); denied integer := 0; BEGIN
  PERFORM watch.fn_reuse_set(gb, 'Terms withdrawn', NULL, current_date, false, false, false, false, false, NULL);
  ASSERT (SELECT active AND paused AND pause_note LIKE '%re-use register%' FROM watch.publication_source WHERE id = src), 'its source is paused at once, with the reason';
  BEGIN PERFORM watch.fn_source_pause(src, false, NULL); EXCEPTION WHEN insufficient_privilege THEN denied := denied + 1; END;
  ASSERT denied = 1, 'it cannot be resumed against the register';
END $$;
RESET ROLE;
DO $$ DECLARE src uuid := (SELECT id FROM _s WHERE code = 'GB'); denied boolean := false; BEGIN
  BEGIN
    INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key) VALUES (src, 'T60-1', current_date - 1, 'GB/national_bulletin/T60-1_abc.pdf');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no file of that registry can be recorded as stored, however it arrives';
  INSERT INTO watch.publication_issue (source_id, issue_no, published_on) VALUES (src, 'T60-2', current_date - 1);
END $$;
-- Bahrain: off, register says no → cannot be switched on
SET LOCAL ROLE meesam_staff;
SELECT set_config('meesam.user_id', current_setting('t60.lead'), true);
DO $$ DECLARE denied boolean := false; BEGIN
  PERFORM watch.fn_reuse_set((SELECT registry_id FROM _s WHERE code = 'BH'), 'No terms found', NULL, current_date, false, NULL, NULL, NULL, NULL, NULL);
  BEGIN PERFORM watch.fn_source_confirm_reuse((SELECT id FROM _s WHERE code = 'BH'), 'trying anyway'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a source cannot be switched on against the register';
  -- allowed again → resume works
  PERFORM watch.fn_reuse_set((SELECT registry_id FROM _s WHERE code = 'GB'), 'Open Government Licence v3.0', NULL, current_date, true, true, true, NULL, false, NULL);
  PERFORM watch.fn_source_pause((SELECT id FROM _s WHERE code = 'GB'), false, NULL);
  ASSERT (SELECT active AND NOT paused FROM watch.publication_source WHERE id = (SELECT id FROM _s WHERE code = 'GB')), 'once the register allows storing, the source can be resumed';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0060 TESTS PASSED
