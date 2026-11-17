-- Tests for migration 0010: the appointment sequence, and that the app role can no longer write appointments directly.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES
  ('00000000-0000-0000-0000-0000000010a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000010b0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff'),
  ('00000000-0000-0000-0000-0000000010c0', 'owner_company', '{"en": "Other owner"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000010f1', '00000000-0000-0000-0000-0000000010a0', '{"en": "mine"}', 'word'),
  ('00000000-0000-0000-0000-0000000010f3', '00000000-0000-0000-0000-0000000010a0', '{"en": "mine too"}', 'word'),
  ('00000000-0000-0000-0000-0000000010f2', '00000000-0000-0000-0000-0000000010c0', '{"en": "theirs"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
  SELECT x.id::uuid, x.fam::uuid, g.id, x.no, DATE '2024-01-01', 'existing', 'free_loaded' FROM registry.registry g,
    (VALUES ('00000000-0000-0000-0000-0000000010e1', '00000000-0000-0000-0000-0000000010f1', 'A1'),
            ('00000000-0000-0000-0000-0000000010e2', '00000000-0000-0000-0000-0000000010f3', 'A2'),
            ('00000000-0000-0000-0000-0000000010e3', '00000000-0000-0000-0000-0000000010f2', 'B1')) x(id, fam, no) WHERE g.code = 'AE';
CREATE TEMP TABLE t10 (id uuid); GRANT ALL ON t10 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- the agency cannot write appointments directly, nor end one through the old procedure
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010b0', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, accepted_at)
        VALUES ('00000000-0000-0000-0000-0000000010c0', '00000000-0000-0000-0000-0000000010b0', 'accepted', 'agency', now());
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'direct insert of an appointment is refused';
  denied := false;
  BEGIN CALL core.sp_end_appointment('00000000-0000-0000-0000-000000000000', 'owner'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the unchecked end procedure is withdrawn from the app role';
END $$;

-- the owner asks the agency, naming two of its records and one that is not its own
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010a0', true);
INSERT INTO t10 SELECT core.fn_appointment_request('00000000-0000-0000-0000-0000000010b0',
  ARRAY['00000000-0000-0000-0000-0000000010e1', '00000000-0000-0000-0000-0000000010e2', '00000000-0000-0000-0000-0000000010e3']::uuid[], 'Please act for us');
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT count(*) FROM core.appointment_record ar JOIN t10 ON t10.id = ar.appointment_id) = 2, 'only the owner''s own records enter the scope';
  BEGIN PERFORM core.fn_appointment_respond((SELECT id FROM t10), true); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the requester cannot accept its own request';
END $$;

-- the agency sees nothing until it accepts
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010b0', true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.record) = 0, 'a requested appointment gives no access'; END $$;
SELECT core.fn_appointment_respond((SELECT id FROM t10), true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 2, 'accepted: the agency sees the two records in scope';
  ASSERT (SELECT count(*) FROM core.record WHERE application_no = 'B1') = 0, 'and not the other owner''s record';
END $$;

-- the owner takes one record out of scope; then ends the appointment
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010a0', true);
SELECT core.fn_appointment_set_records((SELECT id FROM t10), ARRAY['00000000-0000-0000-0000-0000000010e1']::uuid[]);
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010b0', true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.record) = 1, 'per-record revoke removes that record at once'; END $$;
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_appointment_set_records((SELECT id FROM t10), ARRAY['00000000-0000-0000-0000-0000000010e3']::uuid[]); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the agency cannot change the scope';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010c0', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_appointment_end((SELECT id FROM t10)); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a stranger cannot end the appointment';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010a0', true);
SELECT core.fn_appointment_end((SELECT id FROM t10));
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010b0', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 0, 'ended: no access, not even read (item 38)';
  ASSERT (SELECT status::text FROM core.appointment WHERE id = (SELECT id FROM t10)) = 'ended', 'history stays visible to both';
END $$;

-- the agency invites the other owner; the owner accepts and names its record
INSERT INTO t10 SELECT core.fn_appointment_request('00000000-0000-0000-0000-0000000010c0', NULL, 'We can look after your marks');
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010c0', true);
SELECT core.fn_appointment_respond((SELECT a.id FROM core.appointment a WHERE a.status = 'requested'), true, ARRAY['00000000-0000-0000-0000-0000000010e3', '00000000-0000-0000-0000-0000000010e1']::uuid[]);
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000010b0', true);
DO $$ BEGIN ASSERT (SELECT string_agg(application_no, ',') FROM core.record) = 'B1', 'invitation accepted: only that owner''s named record'; END $$;
RESET ROLE;
SELECT 'ALL 0010 TESTS PASSED' AS result;
ROLLBACK;
