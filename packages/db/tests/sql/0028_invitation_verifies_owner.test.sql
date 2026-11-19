-- Tests for migration 0028: an agency's invitation verifies the invited owner without staff review.
BEGIN;
SET client_min_messages = warning;
SELECT platform.fn_staff_account();
INSERT INTO core.app_user (id, account_id, email, name, role, status)
  SELECT '00000000-0000-0000-0000-0000000028f1', id, 'staff@x28.test', 'Staff', 'company_admin', 'active' FROM core.account WHERE is_staff;
INSERT INTO platform.staff_role (user_id, role) VALUES ('00000000-0000-0000-0000-0000000028f1', 'system_admin');
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000028b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000028c0', 'owner_individual', '{"en": "Invited owner"}', 'AE', 'pending_email'),
  ('00000000-0000-0000-0000-0000000028c1', 'owner_individual', '{"en": "Not invited"}', 'AE', 'pending_email'),
  ('00000000-0000-0000-0000-0000000028c2', 'owner_company', '{"en": "Waiting owner"}', 'AE', 'pending_review');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000028b2', '00000000-0000-0000-0000-0000000028b0', 'adm@x28.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000028d0', '00000000-0000-0000-0000-0000000028c0', 'new@x28.test', 'New', 'company_admin', 'invited'),
  ('00000000-0000-0000-0000-0000000028d1', '00000000-0000-0000-0000-0000000028c1', 'plain@x28.test', 'Plain', 'company_admin', 'invited'),
  ('00000000-0000-0000-0000-0000000028d2', '00000000-0000-0000-0000-0000000028c2', 'waiting@x28.test', 'Waiting', 'company_admin', 'active');
INSERT INTO core.verification_token (user_id, purpose, token_hash, expires_at) VALUES
  ('00000000-0000-0000-0000-0000000028d0', 'email_verify', '\x2801', now() + interval '1 day'),
  ('00000000-0000-0000-0000-0000000028d1', 'email_verify', '\x2802', now() + interval '1 day');
CREATE TEMP TABLE t28 (outcome text, appointment_id uuid, invite_id uuid); GRANT ALL ON t28 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000028b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000028b2', true);
-- an address that signed up but has not confirmed its e-mail: the invitation waits
SELECT * FROM core.fn_owner_invite('new@x28.test', 'Join');
-- an owner account already waiting for review: the invitation verifies it and the request goes out at once
INSERT INTO t28 SELECT * FROM core.fn_owner_invite('waiting@x28.test');
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT outcome = 'request' AND appointment_id IS NOT NULL FROM t28), 'an owner waiting for review gets the request at once';
  ASSERT (SELECT verification_status = 'verified' AND verification_method = 'agency_invite' AND verified_at IS NOT NULL FROM core.account WHERE id = '00000000-0000-0000-0000-0000000028c2'), 'and is verified by the invitation';
  ASSERT (SELECT verified_at IS NULL FROM core.account WHERE id = '00000000-0000-0000-0000-0000000028c0'), 'an unconfirmed address is not verified yet';
END $$;

-- the invited address confirms its e-mail: verified without staff review, and the invitation becomes the request
SET LOCAL ROLE meesam_app;
SELECT core.sp_consume_token('\x2801', 'email_verify');
SELECT core.sp_consume_token('\x2802', 'email_verify');
DO $$ BEGIN
  ASSERT core.fn_user_account_verified('00000000-0000-0000-0000-0000000028d0'), 'the invited owner is verified on confirming the address';
  ASSERT core.fn_user_account_verified('00000000-0000-0000-0000-0000000028d1'), 'an owner nobody invited is verified by its e-mail address (0031)';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT verification_method = 'agency_invite' FROM core.account WHERE id = '00000000-0000-0000-0000-0000000028c0'), 'method recorded';
  ASSERT (SELECT verification_method = 'email' FROM core.account WHERE id = '00000000-0000-0000-0000-0000000028c1'), 'not invited: method e-mail, no staff notice';
  ASSERT (SELECT count(*) FROM core.appointment WHERE owner_account_id = '00000000-0000-0000-0000-0000000028c0' AND status = 'requested' AND requested_by = 'agency') = 1, 'the request is waiting for the new owner';
  ASSERT (SELECT count(*) FROM core.owner_invite WHERE status = 'pending') = 0, 'no invitation left waiting';
END $$;
-- the staff are told by e-mail, once
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.fn_staff_notices_take() WHERE email = 'staff@x28.test' AND payload ->> 'email' IN ('new@x28.test', 'waiting@x28.test')) = 2, 'one notice per verified owner for the System Administrator';
  ASSERT (SELECT count(*) FROM platform.fn_staff_notices_take()) = 0, 'a notice is handed over once';
END $$;
RESET ROLE;
SELECT 'ALL 0028 TESTS PASSED' AS result;
ROLLBACK;
