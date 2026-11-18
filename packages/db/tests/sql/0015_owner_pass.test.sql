-- Tests for migration 0015: owner pass — issued by the agency holding the record, single use, the agency keeps managing.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000015a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000015b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000015c0', 'agency_office', '{"en": "Other agency"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000015a1', '00000000-0000-0000-0000-0000000015a0', 'o@x15.test', 'O', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000015b1', '00000000-0000-0000-0000-0000000015b0', 'a@x15.test', 'A', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000015b2', '00000000-0000-0000-0000-0000000015b0', 'v@x15.test', 'V', 'viewer', 'active'),
  ('00000000-0000-0000-0000-0000000015c1', '00000000-0000-0000-0000-0000000015c0', 'c@x15.test', 'C', 'agency_admin', 'active');
-- the agency entered two records of one mark for a client (family held by the agency)
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000015f1', '00000000-0000-0000-0000-0000000015b0', '{"en": "m"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000015e1', '00000000-0000-0000-0000-0000000015f1', g.id, 'P1', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000015e2', '00000000-0000-0000-0000-0000000015f1', g.id, 'P2', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'SA';
CREATE TEMP TABLE t15 (code text); GRANT ALL ON t15 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000015b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000015b2', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_pass_issue('00000000-0000-0000-0000-0000000015e1'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a viewer does not issue';
  denied := false;
  BEGIN INSERT INTO core.owner_pass (record_id, issued_by_account_id, token_hash) VALUES ('00000000-0000-0000-0000-0000000015e1', '00000000-0000-0000-0000-0000000015b0', '\x01');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no direct insert';
END $$;
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000015b1', true);
INSERT INTO t15 SELECT core.fn_pass_issue('00000000-0000-0000-0000-0000000015e1');
INSERT INTO t15 SELECT core.fn_pass_issue('00000000-0000-0000-0000-0000000015e1', 'client@x15.test');
DO $$
DECLARE c1 text := (SELECT code FROM t15 ORDER BY ctid LIMIT 1); c2 text := (SELECT code FROM t15 ORDER BY ctid DESC LIMIT 1);
BEGIN
  ASSERT c2 ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$', 'readable code';
  ASSERT (SELECT count(*) FROM core.fn_pass_preview(c1)) = 0, 'a newer pass replaces the earlier one';
  ASSERT (SELECT agency_name ->> 'en' FROM core.fn_pass_preview(lower(replace(c2, '-', ' ')))) = 'Agency', 'preview, however the code is typed';
END $$;
-- another agency cannot issue for it, nor redeem
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000015c0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000015c1', true);
DO $$
DECLARE denied boolean := false; c2 text := (SELECT code FROM t15 ORDER BY ctid DESC LIMIT 1);
BEGIN
  BEGIN PERFORM core.fn_pass_issue('00000000-0000-0000-0000-0000000015e1'); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'only the agency holding the record issues';
  denied := false;
  BEGIN PERFORM core.fn_pass_redeem(c2); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an agency does not redeem';
END $$;
-- the owner redeems
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000015a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000015a1', true);
DO $$
DECLARE denied boolean := false; c2 text := (SELECT code FROM t15 ORDER BY ctid DESC LIMIT 1);
BEGIN
  ASSERT core.fn_pass_redeem(c2) = '00000000-0000-0000-0000-0000000015e1', 'redeemed';
  ASSERT (SELECT count(*) FROM core.record) = 1, 'the owner now sees that record only';
  ASSERT core.fn_can_access('00000000-0000-0000-0000-0000000015e1', '00000000-0000-0000-0000-0000000015b0'), 'the agency keeps managing it';
  ASSERT (SELECT status = 'accepted' FROM core.appointment WHERE agency_account_id = '00000000-0000-0000-0000-0000000015b0'), 'under an appointment in force';
  BEGIN PERFORM core.fn_pass_redeem(c2); EXCEPTION WHEN invalid_parameter_value THEN denied := true; END;
  ASSERT denied, 'single use';
  PERFORM core.fn_appointment_end((SELECT id FROM core.appointment));
  ASSERT NOT core.fn_can_access('00000000-0000-0000-0000-0000000015e1', '00000000-0000-0000-0000-0000000015b0'), 'the owner can end it';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT f.owner_account_id FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = '00000000-0000-0000-0000-0000000015e2') = '00000000-0000-0000-0000-0000000015b0',
    'the other record of the family stays with the agency';
END $$;
SELECT 'ALL 0015 TESTS PASSED' AS result;
ROLLBACK;
