-- Tests for migration 0008: correcting certificate dates re-flows the clocks; the certificate's expiry drives them.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-00000000008a', 'owner_company', '{"en": "E"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-00000000008a', 'e@x.test', 'E', 'company_admin', 'active');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000008a', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000008a1', true);
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000008f1', '00000000-0000-0000-0000-00000000008a', '{"en": "Milpa"}', 'combined');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000008e1', '00000000-0000-0000-0000-0000000008f1', id, '488477', '488477', DATE '0026-08-12', 'existing', 'free_loaded' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id) VALUES
  ('00000000-0000-0000-0000-0000000008e1', 'filed', DATE '0026-08-12', 'manual', '{}', '00000000-0000-0000-0000-00000000008a');
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id) VALUES
  ('00000000-0000-0000-0000-0000000008e1', 'registered', DATE '2026-11-11', 'manual', '{}', '00000000-0000-0000-0000-00000000008a');
DO $$ BEGIN ASSERT (SELECT expiry_date FROM core.record WHERE id = '00000000-0000-0000-0000-0000000008e1') = DATE '0036-08-12', 'wrong year reproduces the defect'; END $$;

-- the user corrects the dates on the Certificate tab
SELECT core.fn_correct_certificate('00000000-0000-0000-0000-0000000008e1', NULL, DATE '2026-08-12', NULL, DATE '2026-11-11', DATE '2036-08-12');
DO $$
DECLARE rid uuid := '00000000-0000-0000-0000-0000000008e1';
BEGIN
  ASSERT (SELECT expiry_date FROM core.record WHERE id = rid) = DATE '2036-08-12', 'expiry corrected';
  ASSERT (SELECT event_date FROM core.record_event WHERE record_id = rid AND event_type = 'filed') = DATE '2026-08-12', 'filed event moved';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = rid AND timer_type = 'expiry' AND state = 'open') = DATE '2036-08-12', 'expiry clock re-flowed';
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = rid AND state = 'open' AND due_date < DATE '2000-01-01') = 0, 'no clock left in year 00xx';
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = rid AND timer_type = 'expiry' AND state = 'open') = 1, 'one open expiry clock';
END $$;

-- a certificate whose expiry differs from the term: the certificate wins and the clocks follow it
SELECT core.fn_correct_certificate('00000000-0000-0000-0000-0000000008e1', NULL, NULL, NULL, NULL, DATE '2036-11-11');
DO $$
DECLARE rid uuid := '00000000-0000-0000-0000-0000000008e1';
BEGIN
  ASSERT (SELECT expiry_date FROM core.record WHERE id = rid) = DATE '2036-11-11', 'certificate expiry kept';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = rid AND timer_type = 'expiry' AND state = 'open') = DATE '2036-11-11', 'expiry clock follows the certificate';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = rid AND timer_type = 'grace' AND state = 'open') = DATE '2037-05-11', 'grace follows the certificate';
END $$;
RESET ROLE;
SELECT 'ALL 0008 TESTS PASSED' AS result;
ROLLBACK;
