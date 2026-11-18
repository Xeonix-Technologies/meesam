-- Tests for migration 0022: a self-declared registry check, withdrawn when certificate information changes.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000022a0', 'owner_company', '{"en": "Owner Co"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000022a1', '00000000-0000-0000-0000-0000000022a0', 'o@x22.test', 'Omar', 'tm_manager', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000022f1', '00000000-0000-0000-0000-0000000022a0', '{"en": "m"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000022e1', '00000000-0000-0000-0000-0000000022f1', g.id, 'R1', DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000022a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000022a1', true);
SELECT core.fn_record_registry_check('00000000-0000-0000-0000-0000000022e1', true);
DO $$ BEGIN
  ASSERT (SELECT registry_checked_at IS NOT NULL AND registry_checked_by ->> 'user' = 'Omar' AND registry_checked_by -> 'account' ->> 'en' = 'Owner Co' FROM core.record WHERE id = '00000000-0000-0000-0000-0000000022e1'), 'who and when are kept';
  UPDATE core.record SET madrid = madrid WHERE id = '00000000-0000-0000-0000-0000000022e1';
  ASSERT (SELECT registry_checked_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-0000000022e1'), 'an unrelated change leaves the check';
  PERFORM core.fn_correct_certificate('00000000-0000-0000-0000-0000000022e1', 'R1', DATE '2024-01-01', NULL, NULL, NULL);
  ASSERT (SELECT registry_checked_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-0000000022e1'), 'saving the same values leaves the check';
  PERFORM core.fn_correct_certificate('00000000-0000-0000-0000-0000000022e1', 'R2', NULL, NULL, NULL, NULL);
  ASSERT (SELECT registry_checked_at IS NULL AND registry_checked_by IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-0000000022e1'), 'changing a number withdraws the check';
  PERFORM core.fn_record_registry_check('00000000-0000-0000-0000-0000000022e1', true);
  PERFORM core.fn_record_registry_check('00000000-0000-0000-0000-0000000022e1', false);
  ASSERT (SELECT registry_checked_at IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-0000000022e1'), 'the user can withdraw it';
END $$;
RESET ROLE;
SELECT 'ALL 0022 TESTS PASSED' AS result;
ROLLBACK;
