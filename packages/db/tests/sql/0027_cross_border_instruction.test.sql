-- Tests for migration 0027: cross-border instruction between agency offices, with the instructed office's edit right.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000027a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000027b0', 'agency_office', '{"en": "Head office"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000027b1', 'agency_office', '{"en": "Local office"}', 'SA', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000027b2', 'agency_office', '{"en": "Stranger office"}', 'SA', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000027a1', '00000000-0000-0000-0000-0000000027a0', 'own@x27.test', 'Own', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000027c0', '00000000-0000-0000-0000-0000000027b0', 'head@x27.test', 'Head', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000027c1', '00000000-0000-0000-0000-0000000027b1', 'local@x27.test', 'Local', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000027c3', '00000000-0000-0000-0000-0000000027b1', 'agent@x27.test', 'Agent', 'agent', 'active'),
  ('00000000-0000-0000-0000-0000000027c2', '00000000-0000-0000-0000-0000000027b2', 'stranger@x27.test', 'Stranger', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000027f1', '00000000-0000-0000-0000-0000000027a0', '{"en": "mark"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027f1', g.id, NULL, NULL, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g WHERE g.code = 'SA';
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000027d0', '00000000-0000-0000-0000-0000000027a0', '00000000-0000-0000-0000-0000000027b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000027d0', '00000000-0000-0000-0000-0000000027e1');
CREATE TEMP TABLE t27 (id uuid); GRANT ALL ON t27 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- an office that does not hold the record cannot instruct on it; nor can the app role write rows directly
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027b2', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027c2', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_instruction_request('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027b1'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an office that does not hold the record cannot instruct on it';
  denied := false;
  BEGIN INSERT INTO core.cross_border_instruction (from_account_id, to_account_id, record_id, status)
        VALUES ('00000000-0000-0000-0000-0000000027b2', '00000000-0000-0000-0000-0000000027b1', '00000000-0000-0000-0000-0000000027e1', 'active');
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'direct insert of an instruction is refused';
END $$;
-- the owner cannot instruct either
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027a1', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_instruction_request('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027b1'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an instruction is sent by an agency office';
END $$;

-- the head office instructs the local office, naming it by the e-mail of one of its users
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027c0', true);
INSERT INTO t27 SELECT core.fn_instruction_request('00000000-0000-0000-0000-0000000027e1', NULL, 'Local@X27.test', 'Please file in KSA');
DO $$
DECLARE bad boolean := false;
BEGIN
  BEGIN PERFORM core.fn_instruction_request('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027b1'); EXCEPTION WHEN unique_violation THEN bad := true; END;
  ASSERT bad, 'one open instruction per record and office';
  bad := false;
  BEGIN PERFORM core.fn_instruction_request('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027a0'); EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'the instructed account must be an agency office';
  ASSERT (SELECT direction = 'sent' AND status = 'requested' AND NOT in_force AND owner_name ->> 'en' = 'Owner' FROM core.fn_instruction_list()), 'the sender lists it';
END $$;

-- the local office: sees the request, not the record; an agent cannot answer; the administrator accepts
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027c3', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.record WHERE id = '00000000-0000-0000-0000-0000000027e1') = 0, 'no access before accepting';
  ASSERT (SELECT direction = 'received' AND mark_text ->> 'en' = 'mark' AND registry_code = 'SA' AND other_name ->> 'en' = 'Head office' FROM core.fn_instruction_list()), 'the request names the mark, the registry and the sender';
  BEGIN PERFORM core.fn_instruction_respond((SELECT id FROM t27), true); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an agent does not answer an instruction';
END $$;
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027c1', true);
SELECT core.fn_instruction_respond((SELECT id FROM t27), true);
-- ruling 17: the instructed office reads and edits the record, and records the local application
UPDATE core.record SET application_no = 'SA-123', filing_date = DATE '2026-11-01' WHERE id = '00000000-0000-0000-0000-0000000027e1';
DO $$ BEGIN
  ASSERT (SELECT application_no FROM core.record WHERE id = '00000000-0000-0000-0000-0000000027e1') = 'SA-123', 'the instructed office edits the record';
  ASSERT (SELECT name ->> 'en' FROM core.account WHERE id = '00000000-0000-0000-0000-0000000027a0') = 'Owner', 'the instructed office sees the owner';
  ASSERT (SELECT name ->> 'en' FROM core.account WHERE id = '00000000-0000-0000-0000-0000000027b0') = 'Head office', 'and the instructing office';
END $$;

-- the owner is told of the change, is not shown the instructed office, and reads the change as made through its agency
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027a1', true);
DO $$
DECLARE a record;
BEGIN
  ASSERT (SELECT count(*) FROM core.account WHERE id = '00000000-0000-0000-0000-0000000027b1') = 0, 'the owner cannot read the instructed office';
  ASSERT (SELECT count(*) FROM core.cross_border_instruction) = 0, 'nor the instruction';
  ASSERT (SELECT count(*) FROM core.record_edit WHERE record_id = '00000000-0000-0000-0000-0000000027e1' AND account_id = '00000000-0000-0000-0000-0000000027b1' AND notified_account_id = '00000000-0000-0000-0000-0000000027a0') >= 1, 'the owner is notified of the edit';
  SELECT * INTO a FROM core.fn_record_actor('00000000-0000-0000-0000-0000000027e1', '00000000-0000-0000-0000-0000000027b1');
  ASSERT a.name IS NULL AND a.through ->> 'en' = 'Head office', 'handled through the instructing agency';
END $$;
-- a stranger office learns nothing
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027b2', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027c2', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.fn_instruction_list()) = 0, 'no instructions for a stranger';
  BEGIN PERFORM core.fn_instruction_end((SELECT id FROM t27)); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a stranger cannot end it';
END $$;

-- when the head office's appointment ends, the instructed office loses the record at once
RESET ROLE;
UPDATE core.appointment SET status = 'ended', ended_at = now(), ended_by = 'owner' WHERE id = '00000000-0000-0000-0000-0000000027d0';
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000027b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000027c1', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record WHERE id = '00000000-0000-0000-0000-0000000027e1') = 0, 'no access once the instructing office no longer holds the record';
  ASSERT (SELECT NOT in_force FROM core.fn_instruction_list()), 'and the list says it is not in force';
  PERFORM core.fn_instruction_end((SELECT id FROM t27));
  ASSERT (SELECT status FROM core.fn_instruction_list()) = 'ended', 'either office ends it';
END $$;
RESET ROLE;
SELECT 'ALL 0027 TESTS PASSED' AS result;
ROLLBACK;
