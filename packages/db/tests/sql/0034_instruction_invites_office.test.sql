-- Tests for migration 0034: instructing an agency office that is not on Meesam yet.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000034a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000034b0', 'agency_office', '{"en": "Head office"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000034b1', 'agency_office', '{"en": "Known office"}', 'SA', now(), 'staff', 'verified');
INSERT INTO core.account (id, kind, name, country, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000034b2', 'agency_office', '{"en": "New office"}', 'EG', 'pending_review');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000034a1', '00000000-0000-0000-0000-0000000034a0', 'own@x34.test', 'Own', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000034c0', '00000000-0000-0000-0000-0000000034b0', 'head@x34.test', 'Head', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000034c1', '00000000-0000-0000-0000-0000000034b1', 'known@x34.test', 'Known', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000034f1', '00000000-0000-0000-0000-0000000034a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000034e1', '00000000-0000-0000-0000-0000000034f1', g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'SA';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, sha256) VALUES
  ('00000000-0000-0000-0000-0000000034d2', '00000000-0000-0000-0000-0000000034e1', 'POA', 'x34/poa.pdf', 'poa.pdf', '\x02');
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000034aa', '00000000-0000-0000-0000-0000000034a0', '00000000-0000-0000-0000-0000000034b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000034aa', '00000000-0000-0000-0000-0000000034e1');
CREATE TEMP TABLE t34 (outcome text, instruction_id uuid, invite_id uuid); GRANT ALL ON t34 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000034b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000034c0', true);
-- an office already on Meesam: the instruction goes out at once
INSERT INTO t34 SELECT * FROM core.fn_instruction_by_email('00000000-0000-0000-0000-0000000034e1', 'Known@X34.test', 'Hello');
DO $$
DECLARE bad boolean := false;
BEGIN
  ASSERT (SELECT outcome = 'request' AND instruction_id IS NOT NULL AND invite_id IS NULL FROM t34), 'an office on Meesam gets the instruction at once';
  BEGIN PERFORM * FROM core.fn_instruction_by_email('00000000-0000-0000-0000-0000000034e1', 'own@x34.test'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'an owner''s address is not an office';
  bad := false;
  BEGIN PERFORM * FROM core.fn_instruction_by_email('00000000-0000-0000-0000-0000000034e1', 'head@x34.test'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'an office does not instruct itself';
END $$;
-- an address not on Meesam: the instruction waits as an invitation, with its documents
TRUNCATE t34;
INSERT INTO t34 SELECT * FROM core.fn_instruction_by_email('00000000-0000-0000-0000-0000000034e1', 'new@x34.test', 'Please file in Egypt', NULL, '00000000-0000-0000-0000-0000000034d2');
DO $$
DECLARE bad boolean := false;
BEGIN
  ASSERT (SELECT outcome = 'invited' AND instruction_id IS NULL AND invite_id IS NOT NULL FROM t34), 'an unknown address gets an invitation';
  BEGIN PERFORM * FROM core.fn_instruction_by_email('00000000-0000-0000-0000-0000000034e1', 'new@x34.test'); EXCEPTION WHEN unique_violation THEN bad := true; END;
  ASSERT bad, 'one waiting invitation per trademark and address';
  ASSERT (SELECT count(*) FROM core.instruction_invite WHERE status = 'pending') = 1, 'the sender reads its waiting invitation';
  bad := false;
  BEGIN INSERT INTO core.instruction_invite (from_account_id, record_id, email) VALUES ('00000000-0000-0000-0000-0000000034b0', '00000000-0000-0000-0000-0000000034e1', 'x@x34.test'); EXCEPTION WHEN insufficient_privilege THEN bad := true; END;
  ASSERT bad, 'the app role cannot write invitations directly';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000034b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000034c1', true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.instruction_invite) = 0, 'invitations are private to the sender'; END $$;
RESET ROLE;

-- the address joins an agency office: nothing until staff verify the office, then the invitation becomes the instruction
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000034c2', '00000000-0000-0000-0000-0000000034b2', 'new@x34.test', 'New', 'agency_admin', 'active');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.cross_border_instruction WHERE to_account_id = '00000000-0000-0000-0000-0000000034b2') = 0, 'no instruction before the office is verified';
END $$;
UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = 'staff' WHERE id = '00000000-0000-0000-0000-0000000034b2';
DO $$ BEGIN
  ASSERT (SELECT status = 'requested' AND message = 'Please file in Egypt' AND poa_doc_id = '00000000-0000-0000-0000-0000000034d2' AND from_account_id = '00000000-0000-0000-0000-0000000034b0'
            FROM core.cross_border_instruction WHERE to_account_id = '00000000-0000-0000-0000-0000000034b2'), 'the invitation became the instruction, with its message and document';
  ASSERT (SELECT status = 'converted' AND instruction_id IS NOT NULL FROM core.instruction_invite WHERE email = 'new@x34.test'), 'and is closed';
END $$;
SET LOCAL ROLE meesam_staff;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.fn_instruction_invite_mails_take() WHERE email = 'new@x34.test' AND sender ->> 'en' = 'Head office' AND registry_code = 'SA') = 1, 'the new office is e-mailed once';
  ASSERT (SELECT count(*) FROM platform.fn_instruction_invite_mails_take()) = 0, 'handed over once';
END $$;
RESET ROLE;

-- an invitation lapses when the sender no longer holds the trademark
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000034b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000034c0', true);
SELECT * FROM core.fn_instruction_by_email('00000000-0000-0000-0000-0000000034e1', 'late@x34.test');
RESET ROLE;
UPDATE core.appointment SET status = 'ended', ended_at = now(), ended_by = 'owner' WHERE id = '00000000-0000-0000-0000-0000000034aa';
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000034b3', 'agency_office', '{"en": "Late office"}', 'JO', now(), 'staff', 'verified');
INSERT INTO core.app_user (account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000034b3', 'late@x34.test', 'Late', 'agency_admin', 'active');
DO $$ BEGIN
  ASSERT (SELECT status FROM core.instruction_invite WHERE email = 'late@x34.test') = 'lapsed', 'lapsed: the sender no longer holds the trademark';
  ASSERT (SELECT count(*) FROM core.cross_border_instruction WHERE to_account_id = '00000000-0000-0000-0000-0000000034b3') = 0, 'and no instruction was created';
END $$;
SELECT 'ALL 0034 TESTS PASSED' AS result;
ROLLBACK;
