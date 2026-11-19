-- Bulk import (web: lib/importer.ts): the statements the import runs as the app role are accepted, a loaded
-- row gets its stage and clocks like a single added trademark, and staged files are private to the account.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000040a0', 'agency_office', '{"en": "Agency"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000040a9', 'owner_company', '{"en": "Other"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-0000000040c0', '00000000-0000-0000-0000-0000000040a0', 'adm@x40.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-0000000040c9', '00000000-0000-0000-0000-0000000040a9', 'oth@x40.test', 'Oth', 'company_admin', 'active');
CREATE TEMP TABLE t40 (batch uuid, fam uuid, rec uuid); GRANT ALL ON t40 TO meesam_app;

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000040a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000040c0', true);
-- stage a file
WITH b AS (INSERT INTO platform.import_batch (account_id, user_id, status, summary) VALUES ('00000000-0000-0000-0000-0000000040a0', '00000000-0000-0000-0000-0000000040c0', 'staged', '{"file_name": "list.csv"}') RETURNING id)
INSERT INTO t40 (batch) SELECT id FROM b;
INSERT INTO platform.import_row (batch_id, row_no, raw) SELECT batch, 1, '{"cells": ["AE", "mark", "123", "2021-03-15"]}' FROM t40;
-- load the row: the same statements as a single added trademark, marked as a bulk import
WITH f AS (INSERT INTO core.mark_family (owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000040a0', '{"en": "mark"}', 'word') RETURNING id)
UPDATE t40 SET fam = (SELECT id FROM f);
WITH r AS (INSERT INTO core.record (mark_family_id, registry_id, application_no, registration_no, filing_date, mark_text, entry_mode, paid_state, warnings)
           SELECT t.fam, g.id, '123', '456', DATE '2021-03-15', '{"en": "mark"}', 'bulk_import', 'free_loaded', '[]' FROM t40 t, registry.registry g WHERE g.code = 'AE' RETURNING id)
UPDATE t40 SET rec = (SELECT id FROM r);
INSERT INTO core.record_class (record_id, nice_class_id) SELECT t.rec, c.id FROM t40 t, registry.nice_class c WHERE c.number = 29;
INSERT INTO core.record_registry_scope (record_id, registry_id, kind) SELECT t.rec, r.registry_id, 'filed' FROM t40 t JOIN core.record r ON r.id = t.rec;
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  SELECT rec, 'filed', DATE '2021-03-15', 'bulk_import', '{"via": "import"}', '00000000-0000-0000-0000-0000000040a0' FROM t40;
INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  SELECT rec, 'registered', DATE '2021-09-20', 'bulk_import', '{"via": "import"}', '00000000-0000-0000-0000-0000000040a0' FROM t40;
SELECT core.fn_close_historical_timers(rec) FROM t40;
UPDATE platform.import_row SET record_id = (SELECT rec FROM t40) WHERE batch_id = (SELECT batch FROM t40);
UPDATE platform.import_batch SET status = 'committed', committed_at = now(), summary = summary || '{"loaded": 1}' WHERE id = (SELECT batch FROM t40);
DO $$ BEGIN
  ASSERT (SELECT stage = 'registration' FROM core.v_record_state WHERE record_id = (SELECT rec FROM t40)), 'an imported registered mark stands at the registration stage';
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = (SELECT rec FROM t40) AND state = 'open' AND timer_type IN ('expiry', 'renewal_window')) = 2, 'with its renewal and expiry clocks';
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = (SELECT rec FROM t40) AND state = 'open' AND timer_type IN ('oppose', 'pay_registration')) = 0, 'and no filing-stage clock left open';
END $$;
-- another account sees neither the staged file nor the trademark
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000040a9', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000040c9', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.import_batch) = 0 AND (SELECT count(*) FROM platform.import_row) = 0, 'a staged import is private to its account';
  ASSERT (SELECT count(*) FROM core.record WHERE id = (SELECT rec FROM t40)) = 0, 'and so is what it loaded';
END $$;
RESET ROLE;
SELECT 'ALL BULK IMPORT TESTS PASSED' AS result;
ROLLBACK;
