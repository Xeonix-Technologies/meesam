-- Tests for migration 0018: a pass sent to an address is redeemed only by a user with that address.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000018b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000018a0', 'owner_company', '{"en": "Named"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000018c0', 'owner_company', '{"en": "Other"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000018b1', '00000000-0000-0000-0000-0000000018b0', 'agent@x18.test', 'A', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000018a1', '00000000-0000-0000-0000-0000000018a0', 'named@x18.test', 'N', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000018c1', '00000000-0000-0000-0000-0000000018c0', 'other@x18.test', 'O', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000018f1', '00000000-0000-0000-0000-0000000018b0', '{"en": "one"}', 'word'),
  ('00000000-0000-0000-0000-0000000018f2', '00000000-0000-0000-0000-0000000018b0', '{"en": "two"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000018e1', '00000000-0000-0000-0000-0000000018f1', g.id, 'W1', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000018e2', '00000000-0000-0000-0000-0000000018f2', g.id, 'W2', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
CREATE TEMP TABLE t18 (k text, code text); GRANT ALL ON t18 TO meesam_app;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000018b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000018b1', true);
INSERT INTO t18 SELECT 'named', core.fn_pass_issue('00000000-0000-0000-0000-0000000018e1', 'named@x18.test');
INSERT INTO t18 SELECT 'open', core.fn_pass_issue('00000000-0000-0000-0000-0000000018e2');
-- a verified owner the pass was not sent to
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000018c0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000018c1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_pass_redeem((SELECT code FROM t18 WHERE k = 'named')); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a pass sent to another address is refused, even for a verified owner';
  ASSERT core.fn_pass_redeem((SELECT code FROM t18 WHERE k = 'open')) = '00000000-0000-0000-0000-0000000018e2', 'a bare code is redeemed by the verified owner holding it';
END $$;
-- the addressee: the pass is still good after the refused attempt
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000018a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000018a1', true);
DO $$ BEGIN
  ASSERT core.fn_pass_redeem((SELECT code FROM t18 WHERE k = 'named')) = '00000000-0000-0000-0000-0000000018e1', 'the addressee redeems it';
END $$;
RESET ROLE;
SELECT 'ALL 0018 TESTS PASSED' AS result;
ROLLBACK;
