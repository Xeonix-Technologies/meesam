-- Tests for migration 0026: an agency invites an owner by e-mail.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000026a0', 'owner_company', '{"en": "Known owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000026b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000026b1', 'agency_office', '{"en": "Other agency"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000026c0', 'owner_individual', '{"en": "New owner"}', 'AE', 'pending_review');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000026a1', '00000000-0000-0000-0000-0000000026a0', 'known@x26.test', 'Known', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000026b2', '00000000-0000-0000-0000-0000000026b0', 'adm@x26.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000026b3', '00000000-0000-0000-0000-0000000026b1', 'other@x26.test', 'Other', 'agency_admin', 'active');
CREATE TEMP TABLE t26 (outcome text, appointment_id uuid, invite_id uuid); GRANT ALL ON t26 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- an owner cannot use the agency's entry point
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000026a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000026a1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM * FROM core.fn_owner_invite('someone@x26.test'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an owner account cannot invite an owner';
END $$;

SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000026b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000026b2', true);
-- an existing verified owner receives a request at once (address matched without regard to letter case)
INSERT INTO t26 SELECT * FROM core.fn_owner_invite('Known@X26.test', 'We act for you');
DO $$
DECLARE r t26; bad boolean := false;
BEGIN
  SELECT * INTO r FROM t26;
  ASSERT r.outcome = 'request' AND r.appointment_id IS NOT NULL, 'existing owner: a request';
  ASSERT (SELECT status = 'requested' AND requested_by = 'agency' AND owner_account_id = '00000000-0000-0000-0000-0000000026a0' AND message = 'We act for you'
            FROM core.appointment WHERE id = r.appointment_id), 'the request is from the agency to that owner';
  BEGIN PERFORM * FROM core.fn_owner_invite('known@x26.test'); EXCEPTION WHEN unique_violation THEN bad := true; END;
  ASSERT bad, 'a second request to the same owner is refused while one is open';
  bad := false;
  BEGIN PERFORM * FROM core.fn_owner_invite('other@x26.test'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'an agency address is not invited as an owner';
  bad := false;
  BEGIN PERFORM * FROM core.fn_owner_invite('not an address'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'the address must look like an e-mail address';
  bad := false;
  BEGIN INSERT INTO core.owner_invite (agency_account_id, email) VALUES ('00000000-0000-0000-0000-0000000026b0', 'x@x26.test'); EXCEPTION WHEN insufficient_privilege THEN bad := true; END;
  ASSERT bad, 'the app role cannot write invitations directly';
END $$;

-- an unknown address waits; a second invitation to it is refused; it can be withdrawn and sent again
TRUNCATE t26;
INSERT INTO t26 SELECT * FROM core.fn_owner_invite('new@x26.test', 'Join us');
DO $$
DECLARE r t26; bad boolean := false;
BEGIN
  SELECT * INTO r FROM t26;
  ASSERT r.outcome = 'invited' AND r.appointment_id IS NULL, 'unknown address: an invitation';
  BEGIN PERFORM * FROM core.fn_owner_invite('new@x26.test'); EXCEPTION WHEN unique_violation THEN bad := true; END;
  ASSERT bad, 'one waiting invitation per address and office';
  PERFORM core.fn_owner_invite_withdraw(r.invite_id);
  ASSERT (SELECT status FROM core.owner_invite WHERE id = r.invite_id) = 'withdrawn', 'withdrawn';
  PERFORM * FROM core.fn_owner_invite('new@x26.test', 'Join us again');
  ASSERT (SELECT count(*) FROM core.owner_invite) = 3, 'the office reads its own invitations';
END $$;
-- another office sees none of them and cannot withdraw them
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000026b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000026b3', true);
DO $$
DECLARE bad boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.owner_invite) = 0, 'invitations are private to the office';
  BEGIN PERFORM core.fn_owner_invite_withdraw((SELECT invite_id FROM t26)); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'another office cannot withdraw it';
  PERFORM * FROM core.fn_owner_invite('new@x26.test');
END $$;
RESET ROLE;

-- the address signs up: nothing happens until the account is verified, then each waiting invitation becomes a request
INSERT INTO core.app_user (account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000026c0', 'new@x26.test', 'New', 'company_admin', 'active');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.appointment WHERE owner_account_id = '00000000-0000-0000-0000-0000000026c0') = 0, 'no request before verification';
END $$;
UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = 'staff' WHERE id = '00000000-0000-0000-0000-0000000026c0';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.appointment WHERE owner_account_id = '00000000-0000-0000-0000-0000000026c0' AND status = 'requested' AND requested_by = 'agency') = 2,
    'both offices'' invitations became requests';
  ASSERT (SELECT message FROM core.appointment WHERE owner_account_id = '00000000-0000-0000-0000-0000000026c0' AND agency_account_id = '00000000-0000-0000-0000-0000000026b0') = 'Join us again',
    'the message travels with the request';
  ASSERT (SELECT count(*) FROM core.owner_invite WHERE email = 'new@x26.test' AND status = 'pending') = 0, 'no invitation is left waiting';
  ASSERT (SELECT count(*) FROM core.owner_invite WHERE email = 'new@x26.test' AND status = 'withdrawn') = 1, 'the withdrawn one stays withdrawn';
  ASSERT (SELECT count(*) FROM platform.notification WHERE account_id = '00000000-0000-0000-0000-0000000026c0' AND kind = 'appointment_requested') = 2, 'the owner is told in the app';
END $$;
SELECT 'ALL 0026 TESTS PASSED' AS result;
ROLLBACK;
