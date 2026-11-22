-- Tests for migration 0076: an unpaid trademark is watched while the pilot is free, also before the list's effective date.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-0000000076a1', 'owner_individual', '{"en": "Owner SeventySix"}', 'AE', now(), 'staff');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000076f1', '00000000-0000-0000-0000-0000000076a1', '{"en": "SEVENTYSIX"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000076e1', '00000000-0000-0000-0000-0000000076f1', id, '760100', '{"en": "Seventysix"}', 'existing', 'free_new_pending' FROM registry.registry WHERE code = 'AE';
DO $$ BEGIN
  UPDATE core.price_list SET effective_from = current_date + 30;
  ASSERT (SELECT paid_state NOT IN ('paid', 'read_only_unpaid') FROM core.record WHERE id = '00000000-0000-0000-0000-0000000076e1'), 'the test trademark is unpaid';
  ASSERT core.fn_price_list_rules() ->> 'name' = 'Price List v1.0', 'before any list is in effect, the newest list is used';
  ASSERT core.fn_record_watched('00000000-0000-0000-0000-0000000076e1'), 'an unpaid trademark is watched while the pilot is free, before the list''s effective date too';
  UPDATE core.price_list SET rules = rules || '{"pilot_all_free": false}';
  ASSERT NOT core.fn_record_watched('00000000-0000-0000-0000-0000000076e1'), 'when the pilot is no longer free, an unpaid trademark is not watched';
  UPDATE core.record SET paid_state = 'paid' WHERE id = '00000000-0000-0000-0000-0000000076e1';
  ASSERT core.fn_record_watched('00000000-0000-0000-0000-0000000076e1'), 'a paid trademark is watched';
END $$;
ROLLBACK;
\echo ALL 0076 TESTS PASSED
