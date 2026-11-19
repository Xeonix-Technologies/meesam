-- Tests for migration 0029: an owner instructs an office; an agent answers; the owner is e-mailed when an invitation converts.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000029a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000029b0', 'agency_office', '{"en": "Appointed agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000029b1', 'agency_office', '{"en": "Local office"}', 'SA', now(), 'staff', 'verified');
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000029c0', 'owner_individual', '{"en": "New owner"}', 'AE', 'pending_email'),
  ('00000000-0000-0000-0000-0000000029c1', 'owner_individual', '{"en": "Quiet owner"}', 'AE', 'pending_email');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000029a1', '00000000-0000-0000-0000-0000000029a0', 'own@x29.test', 'Own', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000029a2', '00000000-0000-0000-0000-0000000029a0', 'mgr@x29.test', 'Mgr', 'tm_manager', 'active'),
  ('00000000-0000-0000-0000-0000000029c9', '00000000-0000-0000-0000-0000000029b0', 'head@x29.test', 'Head', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000029c2', '00000000-0000-0000-0000-0000000029b1', 'agent@x29.test', 'Agent', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000029d0', '00000000-0000-0000-0000-0000000029c0', 'new@x29.test', 'New', 'company_admin', 'invited'),
  ('00000000-0000-0000-0000-0000000029d1', '00000000-0000-0000-0000-0000000029c1', 'quiet@x29.test', 'Quiet', 'company_admin', 'invited');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000029f1', '00000000-0000-0000-0000-0000000029a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000029e1', '00000000-0000-0000-0000-0000000029f1', g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'SA';
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000029aa', '00000000-0000-0000-0000-0000000029a0', '00000000-0000-0000-0000-0000000029b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000029aa', '00000000-0000-0000-0000-0000000029e1');
INSERT INTO core.verification_token (user_id, purpose, token_hash, expires_at) VALUES
  ('00000000-0000-0000-0000-0000000029d0', 'email_verify', '\x2901', now() + interval '1 day'),
  ('00000000-0000-0000-0000-0000000029d1', 'email_verify', '\x2902', now() + interval '1 day');
CREATE TEMP TABLE t29 (id uuid); GRANT ALL ON t29 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- (a) the owner (here its trademark manager) instructs an office on its own trademark
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000029a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000029a2', true);
INSERT INTO t29 SELECT core.fn_instruction_request('00000000-0000-0000-0000-0000000029e1', '00000000-0000-0000-0000-0000000029b1', NULL, 'Please handle KSA');
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT direction = 'sent' AND status = 'requested' FROM core.fn_instruction_list()), 'the owner lists the instruction it sent';
  BEGIN PERFORM core.fn_instruction_end((SELECT id FROM t29)); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'withdrawing or ending is for the owner''s administrator';
END $$;
-- (b) an agent of the instructed office accepts
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000029b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000029c2', true);
SELECT core.fn_instruction_respond((SELECT id FROM t29), true);
UPDATE core.record SET application_no = 'SA-29' WHERE id = '00000000-0000-0000-0000-0000000029e1';
DO $$ BEGIN
  ASSERT (SELECT application_no FROM core.record WHERE id = '00000000-0000-0000-0000-0000000029e1') = 'SA-29', 'the instructed office edits the record';
  ASSERT (SELECT count(*) FROM core.fn_message_parties('00000000-0000-0000-0000-0000000029e1')) = 1, 'the office the owner instructed is on the message thread';
  PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000029e1', 'Filed today');
END $$;
-- the owner knows the office it instructed, reads its change under its name, and can write to it
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000029a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000029a1', true);
DO $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM core.fn_record_actor('00000000-0000-0000-0000-0000000029e1', '00000000-0000-0000-0000-0000000029b1');
  ASSERT a.name ->> 'en' = 'Local office', 'the owner is shown the office it instructed itself';
  ASSERT (SELECT count(*) FROM core.fn_message_parties('00000000-0000-0000-0000-0000000029e1')) = 2, 'the owner can write to the appointed agency and to the instructed office';
  ASSERT (SELECT count(*) FROM core.message) = 1, 'the owner reads the office''s message';
  PERFORM core.fn_message_post('00000000-0000-0000-0000-0000000029e1', 'Thank you', '00000000-0000-0000-0000-0000000029b1');
  PERFORM core.fn_instruction_end((SELECT id FROM t29));
END $$;
-- once ended the office is off the record and off the thread
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000029b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000029c2', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record WHERE id = '00000000-0000-0000-0000-0000000029e1') = 0, 'no access after the owner ends the instruction';
  ASSERT (SELECT count(*) FROM core.fn_message_parties('00000000-0000-0000-0000-0000000029e1')) = 0, 'and no longer a message party';
END $$;

-- (c) the owner is e-mailed when an invitation becomes a request, unless the office switched it off
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000029b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000029c9', true);
SELECT * FROM core.fn_owner_invite('new@x29.test', 'Join us');
SELECT * FROM core.fn_owner_invite('quiet@x29.test', NULL, false);
SELECT core.sp_consume_token('\x2901', 'email_verify');
SELECT core.sp_consume_token('\x2902', 'email_verify');
RESET ROLE;
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.fn_invite_request_mails_take() WHERE email = 'new@x29.test' AND agency ->> 'en' = 'Appointed agency' AND note = 'Join us' AND appointment_id IS NOT NULL) = 1,
    'one e-mail for the owner whose invitation became a request';
  ASSERT (SELECT count(*) FROM platform.fn_invite_request_mails_take()) = 0, 'handed over once; none for the invitation with the e-mail switched off';
END $$;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.appointment WHERE owner_account_id IN ('00000000-0000-0000-0000-0000000029c0', '00000000-0000-0000-0000-0000000029c1') AND status = 'requested') = 2, 'both invitations became requests';
END $$;
SELECT 'ALL 0029 TESTS PASSED' AS result;
ROLLBACK;
