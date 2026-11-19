-- Tests for migration 0032: documents attached to an instruction, and naming the instructed office to the owner.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000032a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000032b0', 'agency_office', '{"en": "Head office"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000032b1', 'agency_office', '{"en": "Local office"}', 'SA', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000032b2', 'agency_office', '{"en": "Stranger"}', 'SA', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000032a1', '00000000-0000-0000-0000-0000000032a0', 'own@x32.test', 'Own', 'company_admin', 'active'),
  ('00000000-0000-0000-0000-0000000032c0', '00000000-0000-0000-0000-0000000032b0', 'head@x32.test', 'Head', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000032c1', '00000000-0000-0000-0000-0000000032b1', 'local@x32.test', 'Local', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000032c2', '00000000-0000-0000-0000-0000000032b2', 'str@x32.test', 'Str', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000032f1', '00000000-0000-0000-0000-0000000032a0', '{"en": "mark"}', 'word'),
  ('00000000-0000-0000-0000-0000000032f2', '00000000-0000-0000-0000-0000000032a0', '{"en": "other"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT x.id, x.fam, g.id, 'existing', 'free_loaded', '{"en": "mark"}' FROM registry.registry g,
    (VALUES ('00000000-0000-0000-0000-0000000032e1'::uuid, '00000000-0000-0000-0000-0000000032f1'::uuid),
            ('00000000-0000-0000-0000-0000000032e2'::uuid, '00000000-0000-0000-0000-0000000032f2'::uuid)) x(id, fam) WHERE g.code = 'SA';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, sha256) VALUES
  ('00000000-0000-0000-0000-0000000032d1', '00000000-0000-0000-0000-0000000032e1', 'LGR', 'x32/lgr.pdf', 'request.pdf', '\x01'),
  ('00000000-0000-0000-0000-0000000032d2', '00000000-0000-0000-0000-0000000032e1', 'POA', 'x32/poa.pdf', 'poa.pdf', '\x02'),
  ('00000000-0000-0000-0000-0000000032d3', '00000000-0000-0000-0000-0000000032e2', 'POA', 'x32/other.pdf', 'other.pdf', '\x03');
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000032aa', '00000000-0000-0000-0000-0000000032a0', '00000000-0000-0000-0000-0000000032b0', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000032aa', '00000000-0000-0000-0000-0000000032e1');
CREATE TEMP TABLE t32 (id uuid); GRANT ALL ON t32 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000032b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000032c0', true);
DO $$
DECLARE bad boolean := false;
BEGIN
  BEGIN PERFORM core.fn_instruction_request('00000000-0000-0000-0000-0000000032e1', '00000000-0000-0000-0000-0000000032b1', NULL, NULL, NULL, '00000000-0000-0000-0000-0000000032d3');
  EXCEPTION WHEN invalid_parameter_value THEN bad := true; END;
  ASSERT bad, 'a document of another record cannot be attached';
END $$;
INSERT INTO t32 SELECT core.fn_instruction_request('00000000-0000-0000-0000-0000000032e1', '00000000-0000-0000-0000-0000000032b1', NULL, 'File in KSA',
  '00000000-0000-0000-0000-0000000032d1', '00000000-0000-0000-0000-0000000032d2');

-- the instructed office reads the two attached documents before accepting, and nothing else of the record
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000032b1', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000032c1', true);
DO $$ BEGIN
  ASSERT (SELECT legal_doc_name = 'request.pdf' AND poa_doc_name = 'poa.pdf' AND NOT named_to_owner AND NOT from_is_owner FROM core.fn_instruction_list()), 'the request lists the attached documents';
  ASSERT (SELECT object_key FROM core.fn_instruction_doc((SELECT id FROM t32), 'poa')) = 'x32/poa.pdf', 'the power of attorney opens before accepting';
  ASSERT (SELECT object_key FROM core.fn_instruction_doc((SELECT id FROM t32), 'legal')) = 'x32/lgr.pdf', 'so does the legal request';
  ASSERT (SELECT count(*) FROM core.document) = 0, 'the record''s documents stay closed until it accepts';
  PERFORM core.fn_instruction_respond((SELECT id FROM t32), true);
  ASSERT (SELECT count(*) FROM core.document) = 2, 'after accepting, the record''s documents open';
END $$;
UPDATE core.record SET application_no = 'SA-32' WHERE id = '00000000-0000-0000-0000-0000000032e1';
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM core.fn_instruction_name_to_owner((SELECT id FROM t32), true); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the instructed office cannot name itself to the owner';
END $$;
-- a stranger gets no document
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000032b2', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000032c2', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  BEGIN PERFORM * FROM core.fn_instruction_doc((SELECT id FROM t32), 'poa'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a stranger cannot open an attached document';
END $$;

-- the owner: hidden by default, named once the instructing agency switches it on
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000032a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000032a1', true);
DO $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM core.fn_record_actor('00000000-0000-0000-0000-0000000032e1', '00000000-0000-0000-0000-0000000032b1');
  ASSERT a.name IS NULL AND a.through ->> 'en' = 'Head office', 'by default the owner reads: handled through the agency';
  ASSERT (SELECT count(*) FROM core.fn_record_named_offices('00000000-0000-0000-0000-0000000032e1')) = 0, 'and no office is named';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000032b0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000032c0', true);
SELECT core.fn_instruction_name_to_owner((SELECT id FROM t32), true);
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000032a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000032a1', true);
DO $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM core.fn_record_actor('00000000-0000-0000-0000-0000000032e1', '00000000-0000-0000-0000-0000000032b1');
  ASSERT a.name ->> 'en' = 'Local office', 'with the switch on the owner reads the office by name';
  ASSERT (SELECT office ->> 'en' = 'Local office' AND through ->> 'en' = 'Head office' FROM core.fn_record_named_offices('00000000-0000-0000-0000-0000000032e1')), 'and the record names it';
  ASSERT (SELECT count(*) FROM core.cross_border_instruction) = 0, 'the instruction itself stays between the offices';
END $$;
RESET ROLE;
SELECT 'ALL 0032 TESTS PASSED' AS result;
ROLLBACK;
