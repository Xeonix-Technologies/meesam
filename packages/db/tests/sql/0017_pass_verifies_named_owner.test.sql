-- Tests for migration 0017: a pass sent to an owner's own address verifies that owner's account on redemption.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000017b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000017a0', 'owner_individual', '{"en": "Named"}', 'AE', NULL, NULL, 'pending_review'),
  ('00000000-0000-0000-0000-0000000017c0', 'owner_individual', '{"en": "Someone else"}', 'AE', NULL, NULL, 'pending_review');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000017b1', '00000000-0000-0000-0000-0000000017b0', 'agent@x17.test', 'A', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000017a1', '00000000-0000-0000-0000-0000000017a0', 'named@x17.test', 'N', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000017c1', '00000000-0000-0000-0000-0000000017c0', 'else@x17.test', 'E', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000017f1', '00000000-0000-0000-0000-0000000017b0', '{"en": "one"}', 'word'),
  ('00000000-0000-0000-0000-0000000017f2', '00000000-0000-0000-0000-0000000017b0', '{"en": "two"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000017e1', '00000000-0000-0000-0000-0000000017f1', g.id, 'V1', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000017e2', '00000000-0000-0000-0000-0000000017f2', g.id, 'V2', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
CREATE TEMP TABLE t17 (k text, code text); GRANT ALL ON t17 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000017b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000017b1', true);
INSERT INTO t17 SELECT 'named', core.fn_pass_issue('00000000-0000-0000-0000-0000000017e1', 'Named@x17.test');
INSERT INTO t17 SELECT 'open', core.fn_pass_issue('00000000-0000-0000-0000-0000000017e2');
DO $$ BEGIN
  ASSERT core.fn_pass_addressee((SELECT code FROM t17 WHERE k = 'named'), 'named@x17.test') = 'named', 'named, whatever the letter case';
  ASSERT core.fn_pass_addressee((SELECT code FROM t17 WHERE k = 'named'), 'else@x17.test') = 'other', 'sent to another address';
  ASSERT core.fn_pass_addressee((SELECT code FROM t17 WHERE k = 'open'), 'else@x17.test') = 'open', 'no address given';
  ASSERT core.fn_pass_addressee('NOPE-NOPE-NOPE', 'else@x17.test') IS NULL, 'unknown code';
END $$;
-- an unverified owner the pass was not sent to: refused, for the named pass and for a bare code
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000017c0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000017c1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_pass_redeem((SELECT code FROM t17 WHERE k = 'named')); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a pass sent to someone else does not verify this account';
  denied := false;
  BEGIN PERFORM core.fn_pass_redeem((SELECT code FROM t17 WHERE k = 'open')); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a bare code does not verify an account';
END $$;
-- the named owner: verified by the redemption
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000017a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000017a1', true);
DO $$ BEGIN
  ASSERT core.fn_pass_redeem((SELECT code FROM t17 WHERE k = 'named')) = '00000000-0000-0000-0000-0000000017e1', 'redeemed';
  ASSERT (SELECT verification_status = 'verified' AND verified_at IS NOT NULL AND verification_method = 'owner_pass' FROM core.account WHERE id = '00000000-0000-0000-0000-0000000017a0'), 'the account is verified by the pass';
  ASSERT (SELECT count(*) FROM core.record) = 1, 'and holds the record';
END $$;
RESET ROLE;
DO $$ BEGIN ASSERT (SELECT verification_status = 'pending_review' FROM core.account WHERE id = '00000000-0000-0000-0000-0000000017c0'), 'the other account still waits for review'; END $$;
SELECT 'ALL 0017 TESTS PASSED' AS result;
ROLLBACK;
