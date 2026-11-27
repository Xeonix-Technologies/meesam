-- Tests for migration 0103: an agency's own client list.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000103a00', 'agency_office', '{"en": "Agency 103"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000103b00', 'agency_office', '{"en": "Other agency 103"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000103c00', 'owner_company', '{"en": "Owner 103"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000103a01', '00000000-0000-0000-0000-000000103a00', 'a@x103.test', 'A', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000103b01', '00000000-0000-0000-0000-000000103b00', 'b@x103.test', 'B', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000103c01', '00000000-0000-0000-0000-000000103c00', 'c@x103.test', 'C', 'company_admin', 'active');
CREATE TEMP TABLE t103 (k text PRIMARY KEY, id uuid); GRANT ALL ON t103 TO meesam_app;

-- the key ignores letter case, punctuation and extra spaces, and keeps Arabic letters
DO $$ BEGIN
  ASSERT core.fn_client_key('  Al-Noor  Trading L.L.C. ') = core.fn_client_key('AL NOOR TRADING LLC'), 'two spellings, one key';
  ASSERT core.fn_client_key('شركة  النور') = 'شركةالنور', 'Arabic is kept';
  ASSERT core.fn_client_key(' .,- ') = '', 'punctuation alone is no name';
END $$;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000103a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000103a01', true);
INSERT INTO t103 VALUES ('one', core.fn_client_ensure('Al-Noor Trading L.L.C.')), ('two', core.fn_client_ensure('Al Noor Foods LLC')), ('same', core.fn_client_ensure('AL NOOR   TRADING LLC'));
DO $$ BEGIN
  ASSERT (SELECT id FROM t103 WHERE k = 'one') = (SELECT id FROM t103 WHERE k = 'same'), 'the same name is found, not added twice';
  ASSERT (SELECT id FROM t103 WHERE k = 'one') <> (SELECT id FROM t103 WHERE k = 'two'), 'another name is another client';
  ASSERT core.fn_client_ensure(' - ') IS NULL, 'an empty name gives no client';
  ASSERT (SELECT count(*) FROM core.client) = 2, 'two clients in the list';
  ASSERT (SELECT name FROM core.client WHERE id = (SELECT id FROM t103 WHERE k = 'one')) = 'Al-Noor Trading L.L.C.', 'the first spelling is the one kept';
END $$;
-- the app role cannot write the list directly
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN INSERT INTO core.client (account_id, name, name_key) VALUES ('00000000-0000-0000-0000-000000103a00', 'x', 'x'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no direct insert';
END $$;
-- a mark entered for a client; the list counts it
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type, client_id)
  SELECT '00000000-0000-0000-0000-000000103f01', '00000000-0000-0000-0000-000000103a00', '{"en": "Mark 103"}', 'word', id FROM t103 WHERE k = 'one';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-000000103e01', '00000000-0000-0000-0000-000000103f01', g.id, 'X103-1', 'bulk_import', 'free_loaded' FROM registry.registry g WHERE g.code = 'AE';
DO $$ BEGIN
  ASSERT (SELECT marks FROM core.fn_clients() WHERE id = (SELECT id FROM t103 WHERE k = 'one')) = 1, 'one mark under the client';
  ASSERT (SELECT marks FROM core.fn_clients() WHERE id = (SELECT id FROM t103 WHERE k = 'two')) = 0, 'none under the other';
END $$;

-- another agency sees nothing of this list and cannot attach a mark to it
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000103b00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000103b01', true);
DO $$ DECLARE denied boolean := false; BEGIN
  ASSERT (SELECT count(*) FROM core.client) = 0, 'another agency reads none';
  ASSERT (SELECT count(*) FROM core.fn_clients()) = 0, 'and lists none';
  BEGIN
    INSERT INTO core.mark_family (owner_account_id, name, mark_type, client_id)
      SELECT '00000000-0000-0000-0000-000000103b00', '{"en": "Theirs"}', 'word', id FROM t103 WHERE k = 'one';
  EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a client of another account is refused';
  ASSERT core.fn_client_ensure('Al-Noor Trading L.L.C.') <> (SELECT id FROM t103 WHERE k = 'one'), 'the same name in another agency is its own client';
END $$;

-- an owner keeps no client list
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000103c00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000103c01', true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM core.fn_client_ensure('Someone'); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'an owner account keeps no client list';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0103 TESTS PASSED
