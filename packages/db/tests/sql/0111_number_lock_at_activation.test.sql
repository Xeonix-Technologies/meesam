-- Tests for migration 0111: a registry's number is locked by the active trademark.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000111a00', 'agency_office', '{"en": "Agency 111"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000111b00', 'owner_company', '{"en": "Owner 111"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000111c00', 'owner_company', '{"en": "Third 111"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000111a01', '00000000-0000-0000-0000-000000111a00', 'adm@x111.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000111b01', '00000000-0000-0000-0000-000000111b00', 'own@x111.test', 'Own', 'company_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000111f01', '00000000-0000-0000-0000-000000111a00', '{"en": "Agency copy"}', 'word'),
  ('00000000-0000-0000-0000-000000111f02', '00000000-0000-0000-0000-000000111b00', '{"en": "Owner copy"}', 'word'),
  ('00000000-0000-0000-0000-000000111f03', '00000000-0000-0000-0000-000000111a00', '{"en": "Agency second"}', 'word'),
  ('00000000-0000-0000-0000-000000111f04', '00000000-0000-0000-0000-000000111c00', '{"en": "Third"}', 'word');
-- two accounts each enter the same number while neither mark is active
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
  SELECT v.id::uuid, v.fam::uuid, g.id, 'N111', 'bulk_import', 'free_loaded', '{"en": "M"}'
    FROM registry.registry g, (VALUES ('00000000-0000-0000-0000-000000111e01', '00000000-0000-0000-0000-000000111f01'),
                                      ('00000000-0000-0000-0000-000000111e02', '00000000-0000-0000-0000-000000111f02')) v(id, fam)
   WHERE g.code = 'AE';
DO $$ DECLARE code text := ''; con text := ''; BEGIN
  ASSERT (SELECT count(*) FROM core.record WHERE application_no = 'N111' AND activated_at IS NULL) = 2, 'two waiting copies of one number, in two accounts';
  -- the same account does not enter it twice
  BEGIN
    INSERT INTO core.record (mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
      SELECT '00000000-0000-0000-0000-000000111f03', g.id, 'N111', 'bulk_import', 'free_loaded', '{"en": "M"}' FROM registry.registry g WHERE g.code = 'AE';
  EXCEPTION WHEN unique_violation THEN GET STACKED DIAGNOSTICS con = CONSTRAINT_NAME; code := SQLSTATE; END;
  ASSERT code = '23505' AND con = 'record_number_account', 'once per account: ' || code || ' ' || con;
  -- the same number at another registry is another matter
  INSERT INTO core.record (mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
    SELECT '00000000-0000-0000-0000-000000111f03', g.id, 'N111', 'bulk_import', 'free_loaded', '{"en": "M"}' FROM registry.registry g WHERE g.code = 'SA';
END $$;
-- both wait in their baskets; the owner's copy is activated
UPDATE core.record SET activation_requested_at = now() WHERE application_no = 'N111' AND id IN ('00000000-0000-0000-0000-000000111e01', '00000000-0000-0000-0000-000000111e02');
UPDATE core.record SET activated_at = now() WHERE id = '00000000-0000-0000-0000-000000111e02';
DO $$ DECLARE code text := ''; con text := ''; BEGIN
  -- a second active record with the number is impossible
  BEGIN UPDATE core.record SET activated_at = now() WHERE id = '00000000-0000-0000-0000-000000111e01';
  EXCEPTION WHEN unique_violation THEN GET STACKED DIAGNOSTICS con = CONSTRAINT_NAME; code := SQLSTATE; END;
  ASSERT code = '23505' AND con = 'record_one_per_application', 'one active record per number: ' || code || ' ' || con;
  -- the number can no longer be entered by anyone else
  code := ''; con := '';
  BEGIN
    INSERT INTO core.record (mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
      SELECT '00000000-0000-0000-0000-000000111f04', g.id, 'N111', 'bulk_import', 'free_loaded', '{"en": "M"}' FROM registry.registry g WHERE g.code = 'AE';
  EXCEPTION WHEN unique_violation THEN GET STACKED DIAGNOSTICS con = CONSTRAINT_NAME; code := SQLSTATE; END;
  ASSERT code = '23505' AND con = 'record_number_active', 'an active number is not entered again: ' || code || ' ' || con;
  -- nor corrected onto another record
  INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
    SELECT '00000000-0000-0000-0000-000000111e04', '00000000-0000-0000-0000-000000111f04', g.id, 'N111-X', 'bulk_import', 'free_loaded', '{"en": "M"}' FROM registry.registry g WHERE g.code = 'AE';
  code := ''; con := '';
  BEGIN UPDATE core.record SET application_no = 'N111' WHERE id = '00000000-0000-0000-0000-000000111e04';
  EXCEPTION WHEN unique_violation THEN GET STACKED DIAGNOSTICS con = CONSTRAINT_NAME; code := SQLSTATE; END;
  ASSERT code = '23505' AND con = 'record_number_active', 'nor corrected onto another record: ' || code || ' ' || con;
END $$;

SET LOCAL ROLE meesam_app;
-- the agency's copy gave way: it stays, says so, and leaves the basket at checkout
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000111a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000111a01', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record WHERE id = '00000000-0000-0000-0000-000000111e01') = 1, 'the waiting copy stays in its account';
  ASSERT core.fn_number_taken('00000000-0000-0000-0000-000000111e01'), 'it knows its number is active elsewhere';
  ASSERT NOT core.fn_number_taken('00000000-0000-0000-0000-000000111e02'), 'another account''s record tells this account nothing';
  ASSERT core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000111e01']::uuid[]) = 0, 'it is not put in the basket';
  IF core.fn_basket_free() THEN
    ASSERT core.fn_basket_checkout() = 0, 'checkout activates nothing of it';
    ASSERT (SELECT activation_requested_at IS NULL AND activated_at IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000111e01'), 'and takes it out of the basket';
  END IF;
  -- its administrator can remove it
  PERFORM core.fn_record_remove('00000000-0000-0000-0000-000000111e01');
END $$;
-- the owner's active record is not "taken"
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000111b00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000111b01', true);
DO $$ BEGIN
  ASSERT NOT core.fn_number_taken('00000000-0000-0000-0000-000000111e02'), 'the active record holds its own number';
END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0111 TESTS PASSED
