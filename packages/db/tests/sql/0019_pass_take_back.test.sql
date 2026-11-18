-- Tests for migration 0019: the agency that issued a pass takes the record back; the appointment ends.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000019b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000019c0', 'agency_office', '{"en": "Other agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000019a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000019b1', '00000000-0000-0000-0000-0000000019b0', 'agent@x19.test', 'A', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019c0', 'c@x19.test', 'C', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000019a1', '00000000-0000-0000-0000-0000000019a0', 'o@x19.test', 'O', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000019f1', '00000000-0000-0000-0000-0000000019b0', '{"en": "one"}', 'word'),
  ('00000000-0000-0000-0000-0000000019f2', '00000000-0000-0000-0000-0000000019b0', '{"en": "two"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000019e1', '00000000-0000-0000-0000-0000000019f1', g.id, 'T1', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000019e2', '00000000-0000-0000-0000-0000000019f2', g.id, 'T2', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
CREATE TEMP TABLE t19 (k text, code text); GRANT ALL ON t19 TO meesam_app;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000019b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000019b1', true);
INSERT INTO t19 SELECT 'one', core.fn_pass_issue('00000000-0000-0000-0000-0000000019e1');
INSERT INTO t19 SELECT 'two', core.fn_pass_issue('00000000-0000-0000-0000-0000000019e2');
DO $$ BEGIN ASSERT NOT core.fn_pass_can_take_back('00000000-0000-0000-0000-0000000019e1'), 'nothing to take back before redemption'; END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000019a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000019a1', true);
SELECT core.fn_pass_redeem((SELECT code FROM t19 WHERE k = 'one'));
SELECT core.fn_pass_redeem((SELECT code FROM t19 WHERE k = 'two'));
-- another agency cannot
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000019c0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000019c1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM * FROM core.fn_pass_take_back('00000000-0000-0000-0000-0000000019e1'); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'only the agency that issued the pass';
END $$;
-- the issuing agency takes the first record back: one of two leaves the appointment, which stays in force
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000019b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000019b1', true);
DO $$ BEGIN
  ASSERT core.fn_pass_can_take_back('00000000-0000-0000-0000-0000000019e1'), 'can take back';
  ASSERT (SELECT string_agg(email::text, ',') FROM core.fn_pass_take_back('00000000-0000-0000-0000-0000000019e1')) = 'o@x19.test', 'the owner is told';
  ASSERT (SELECT status = 'accepted' FROM core.appointment), 'the appointment still covers the other trademark';
  ASSERT NOT core.fn_pass_can_take_back('00000000-0000-0000-0000-0000000019e1'), 'once';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000019a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000019a1', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 1, 'the owner no longer has the record taken back';
  PERFORM core.fn_appointment_end((SELECT id FROM core.appointment));
END $$;
-- after the owner ended the appointment the agency has no access, so it cannot take the second one back
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000019b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000019b1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 1, 'the agency holds the record it took back, and only that';
  BEGIN PERFORM * FROM core.fn_pass_take_back('00000000-0000-0000-0000-0000000019e2'); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'no take-back after the owner ended the appointment';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT f.owner_account_id FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = '00000000-0000-0000-0000-0000000019e1') = '00000000-0000-0000-0000-0000000019b0', 'back with the agency';
END $$;
SELECT 'ALL 0019 TESTS PASSED' AS result;
ROLLBACK;
