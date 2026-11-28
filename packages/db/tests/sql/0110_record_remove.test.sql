-- Tests for migration 0110: removing a trademark that was never activated.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000110a00', 'agency_office', '{"en": "Agency 110"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000110b00', 'owner_company', '{"en": "Owner 110"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000110a01', '00000000-0000-0000-0000-000000110a00', 'adm@x110.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000110a02', '00000000-0000-0000-0000-000000110a00', 'agt@x110.test', 'Agt', 'agent', 'active'),
  ('00000000-0000-0000-0000-000000110b01', '00000000-0000-0000-0000-000000110b00', 'own@x110.test', 'Own', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000110f01', '00000000-0000-0000-0000-000000110a00', '{"en": "Waiting"}', 'word'),
  ('00000000-0000-0000-0000-000000110f02', '00000000-0000-0000-0000-000000110a00', '{"en": "Active"}', 'word'),
  ('00000000-0000-0000-0000-000000110f03', '00000000-0000-0000-0000-000000110b00', '{"en": "Owner''s"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
  SELECT v.id::uuid, v.fam::uuid, g.id, v.app, v.mode::core.entry_mode, 'free_loaded', '{"en": "M"}'
    FROM registry.registry g, (VALUES ('00000000-0000-0000-0000-000000110e01', '00000000-0000-0000-0000-000000110f01', '488477', 'bulk_import'),
                                      ('00000000-0000-0000-0000-000000110e02', '00000000-0000-0000-0000-000000110f02', 'X110-2', 'existing'),
                                      ('00000000-0000-0000-0000-000000110e03', '00000000-0000-0000-0000-000000110f03', 'X110-3', 'bulk_import')) v(id, fam, app, mode)
   WHERE g.code = 'AE';
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000110d01', '00000000-0000-0000-0000-000000110e01', 'ORC', 'AE/x110_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('01', 'hex'), '00000000-0000-0000-0000-000000110a00');
CREATE TEMP TABLE t110 (k text PRIMARY KEY, n integer); GRANT ALL ON t110 TO meesam_app;

SET LOCAL ROLE meesam_app;
-- an Agent is not the administrator
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000110a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000110a02', true);
DO $$ DECLARE code text := ''; BEGIN
  BEGIN PERFORM core.fn_record_remove('00000000-0000-0000-0000-000000110e01'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '42501', 'an Agent does not remove a trademark: ' || code;
END $$;
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000110a01', true);
DO $$ DECLARE code text := ''; c record; BEGIN
  -- the app role cannot remove by writing the column
  BEGIN UPDATE core.record SET removed_at = now() WHERE id = '00000000-0000-0000-0000-000000110e01'; EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '42501', 'no direct removal: ' || code;
  -- an activated mark is closed, never removed
  code := '';
  BEGIN PERFORM core.fn_record_remove('00000000-0000-0000-0000-000000110e02'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '55000', 'an activated trademark is not removed: ' || code;
  -- another account''s mark is not this account''s to remove
  code := '';
  BEGIN PERFORM core.fn_record_remove('00000000-0000-0000-0000-000000110e03'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '22023', 'another account''s trademark: ' || code;
  -- the administrator removes the mark that waits
  ASSERT (SELECT count(*) FROM core.record) = 2 AND (SELECT waiting FROM core.fn_activation_counts()) = 1, 'two marks seen, one waiting';
  PERFORM core.fn_record_remove('00000000-0000-0000-0000-000000110e01');
  ASSERT (SELECT count(*) FROM core.record) = 1, 'the removed mark is gone from the portfolio';
  ASSERT (SELECT count(*) FROM core.record WHERE id = '00000000-0000-0000-0000-000000110e01') = 0, 'and cannot be opened';
  ASSERT (SELECT count(*) FROM core.document WHERE record_id = '00000000-0000-0000-0000-000000110e01') = 0, 'nor can its documents';
  ASSERT (SELECT waiting FROM core.fn_activation_counts()) = 0 AND (SELECT count(*) FROM core.fn_basket()) = 0, 'nor is it waiting or in the basket';
  ASSERT NOT core.fn_i_hold_record('00000000-0000-0000-0000-000000110e01'), 'it is held by no one';
  -- removing it twice finds nothing
  code := '';
  BEGIN PERFORM core.fn_record_remove('00000000-0000-0000-0000-000000110e01'); EXCEPTION WHEN OTHERS THEN code := SQLSTATE; END;
  ASSERT code = '22023', 'already removed: ' || code;
END $$;
-- the number is free again: the owner's account can now hold it
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000110b00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000110b01', true);
DO $$ BEGIN
  UPDATE core.record SET application_no = '488477' WHERE id = '00000000-0000-0000-0000-000000110e03';
  ASSERT (SELECT application_no FROM core.record WHERE id = '00000000-0000-0000-0000-000000110e03') = '488477', 'the number is free for another record';
END $$;
RESET ROLE;
DO $$ DECLARE r record; BEGIN
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-000000110e01';
  ASSERT r.removed_at IS NOT NULL AND r.removed_by_user_id = '00000000-0000-0000-0000-000000110a01' AND r.removed_by_account_id = '00000000-0000-0000-0000-000000110a00', 'the row is kept, with who removed it';
  ASSERT (SELECT count(*) FROM core.document WHERE record_id = r.id) = 1, 'its documents are kept';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE table_name = 'record' AND row_id = r.id AND action = 'UPDATE' AND after ->> 'removed_at' IS NOT NULL
            AND account_id = '00000000-0000-0000-0000-000000110a00') = 1, 'the removal is in the audit record';
END $$;
ROLLBACK;
\echo ALL 0110 TESTS PASSED
