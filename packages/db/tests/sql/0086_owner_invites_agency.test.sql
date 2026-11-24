-- Tests for migration 0086: an owner invites an agency by e-mail.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000086a0', 'owner_company', '{"en": "Owner 86"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000086a9', 'owner_company', '{"en": "Other owner 86"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000086b0', 'agency_office', '{"en": "Known agency 86"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000086c0', 'agency_office', '{"en": "New agency 86"}', 'TR', 'pending_review');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000086a1', '00000000-0000-0000-0000-0000000086a0', 'owner@x86.test', 'Owner', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000086aa', '00000000-0000-0000-0000-0000000086a9', 'other@x86.test', 'Other', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000086b1', '00000000-0000-0000-0000-0000000086b0', 'agent@x86.test', 'Agent', 'agency_admin', 'active');
CREATE TEMP TABLE t86 (outcome text, appointment_id uuid, invite_id uuid); GRANT ALL ON t86 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- an agency office cannot use the owner's entry point
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000086b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000086b1', true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM * FROM core.fn_agency_invite('someone@x86.test'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an agency office cannot invite an agency';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000086a0', true);

-- the owner's administrator: an agency already on Meesam receives the request at once
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000086a1', true);
INSERT INTO t86 SELECT * FROM core.fn_agency_invite('AGENT@x86.test', 'Please act for us');
DO $$ DECLARE r t86; BEGIN
  SELECT * INTO r FROM t86;
  ASSERT r.outcome = 'request' AND r.appointment_id IS NOT NULL, 'an existing agency gets a request';
END $$;
-- an address of an owner is refused; a malformed one too
DO $$ DECLARE bad boolean := false; BEGIN
  BEGIN PERFORM * FROM core.fn_agency_invite('other@x86.test'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'an owner''s address is not an agency';
  bad := false;
  BEGIN PERFORM * FROM core.fn_agency_invite('not an address'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'a malformed address is refused';
END $$;
-- an unknown address waits; a second invitation to it is refused; the owner sees its own invitations only
DELETE FROM t86;
INSERT INTO t86 SELECT * FROM core.fn_agency_invite('new@x86.test', 'Join us on Meesam');
DO $$ DECLARE r t86; dup boolean := false; BEGIN
  SELECT * INTO r FROM t86;
  ASSERT r.outcome = 'invited' AND r.appointment_id IS NULL, 'an unknown address is invited';
  BEGIN PERFORM * FROM core.fn_agency_invite('new@x86.test'); EXCEPTION WHEN unique_violation THEN dup := true; END;
  ASSERT dup, 'one waiting invitation per address';
  ASSERT (SELECT count(*) FROM core.agency_invite WHERE status = 'pending') = 1, 'the owner reads its waiting invitation';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000086a9', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000086aa', true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.agency_invite) = 0, 'another owner sees none of them'; END $$;
RESET ROLE;

-- the invited address opens an agency office: nothing happens until the office is verified, then the request is there
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000086c1', '00000000-0000-0000-0000-0000000086c0', 'new@x86.test', 'New agent', 'agency_admin', 'active');
DO $$ BEGIN
  ASSERT (SELECT status FROM core.agency_invite WHERE email = 'new@x86.test') = 'pending', 'waits for the verification of the office';
  UPDATE core.account SET verified_at = now(), verification_method = 'staff', verification_status = 'verified' WHERE id = '00000000-0000-0000-0000-0000000086c0';
  ASSERT (SELECT status FROM core.agency_invite WHERE email = 'new@x86.test') = 'converted', 'converted on verification';
  ASSERT EXISTS (SELECT 1 FROM core.appointment WHERE owner_account_id = '00000000-0000-0000-0000-0000000086a0'
                   AND agency_account_id = '00000000-0000-0000-0000-0000000086c0' AND status = 'requested' AND requested_by = 'owner'
                   AND message = 'Join us on Meesam'), 'the request reaches the new office, asked by the owner';
  ASSERT EXISTS (SELECT 1 FROM platform.notification WHERE account_id = '00000000-0000-0000-0000-0000000086a0' AND kind = 'agency_invite_joined'), 'the owner is told';
END $$;

-- a waiting invitation can be withdrawn by its owner only
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000086a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000086a1', true);
DELETE FROM t86;
INSERT INTO t86 SELECT * FROM core.fn_agency_invite('later@x86.test');
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000086a9', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000086aa', true);
DO $$ DECLARE bad boolean := false; BEGIN
  BEGIN PERFORM core.fn_agency_invite_withdraw((SELECT invite_id FROM t86)); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'another owner cannot withdraw it';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000086a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000086a1', true);
SELECT core.fn_agency_invite_withdraw((SELECT invite_id FROM t86));
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.agency_invite WHERE status = 'pending') = 0, 'withdrawn'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0086 TESTS PASSED
