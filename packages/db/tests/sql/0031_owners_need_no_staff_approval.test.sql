-- Tests for migration 0031: an owner is verified on confirming the e-mail address; an agency still waits for staff.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000031a0', 'owner_individual', '{"en": "Person"}', 'AE', 'pending_email'),
  ('00000000-0000-0000-0000-0000000031a1', 'owner_company', '{"en": "Company"}', 'AE', 'pending_email'),
  ('00000000-0000-0000-0000-0000000031a2', 'agency_office', '{"en": "Agency"}', 'AE', 'pending_email'),
  ('00000000-0000-0000-0000-0000000031a3', 'owner_company', '{"en": "Rejected"}', 'AE', 'rejected');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000031b0', '00000000-0000-0000-0000-0000000031a0', 'p@x31.test', 'P', 'company_admin', 'invited'),
  ('00000000-0000-0000-0000-0000000031b1', '00000000-0000-0000-0000-0000000031a1', 'c@x31.test', 'C', 'company_admin', 'invited'),
  ('00000000-0000-0000-0000-0000000031b2', '00000000-0000-0000-0000-0000000031a2', 'a@x31.test', 'A', 'agency_admin', 'invited');
INSERT INTO core.verification_token (user_id, purpose, token_hash, expires_at) VALUES
  ('00000000-0000-0000-0000-0000000031b0', 'email_verify', '\x3101', now() + interval '1 day'),
  ('00000000-0000-0000-0000-0000000031b1', 'email_verify', '\x3102', now() + interval '1 day'),
  ('00000000-0000-0000-0000-0000000031b2', 'email_verify', '\x3103', now() + interval '1 day');
SET LOCAL ROLE meesam_app;
SELECT core.sp_consume_token('\x3101', 'email_verify');
SELECT core.sp_consume_token('\x3102', 'email_verify');
SELECT core.sp_consume_token('\x3103', 'email_verify');
RESET ROLE;
-- a rejected owner who is sent back to review stays with staff
UPDATE core.account SET verification_status = 'pending_review' WHERE id = '00000000-0000-0000-0000-0000000031a3';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.account WHERE id IN ('00000000-0000-0000-0000-0000000031a0', '00000000-0000-0000-0000-0000000031a1')
            AND verification_status = 'verified' AND verified_at IS NOT NULL AND verification_method = 'email') = 2, 'owners are verified on confirming the e-mail address';
  ASSERT (SELECT verification_status = 'pending_review' AND verified_at IS NULL FROM core.account WHERE id = '00000000-0000-0000-0000-0000000031a2'), 'an agency office still waits for staff';
  ASSERT (SELECT verification_status = 'pending_review' AND verified_at IS NULL FROM core.account WHERE id = '00000000-0000-0000-0000-0000000031a3'), 'an owner rejected earlier is not verified by this rule';
END $$;
SELECT 'ALL 0031 TESTS PASSED' AS result;
ROLLBACK;
