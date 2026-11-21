-- 0059 — Price List v1.0 (Founder, 21 Nov 2026): the scale, the introductory price, the filing fee and its credit.
\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE p record; y int; list int[] := ARRAY[195,195,195,195,240,288,336,384,432,480]; intro int[] := ARRAY[195,195,195,195,195,222,259,296,333,370];
BEGIN
  -- the two columns of the years-remaining table, row by row (a day inside each year counts as that year)
  FOR y IN 1..10 LOOP
    SELECT * INTO p FROM core.fn_price('existing_watch', (DATE '2026-12-02' + make_interval(years => y) - interval '10 days')::date, DATE '2026-12-02');
    ASSERT p.years_remaining = y, 'years ' || y || ' read as ' || p.years_remaining;
    ASSERT p.list_amount = list[y], 'list price at ' || y || ' years: ' || p.list_amount;
    ASSERT p.amount = intro[y] AND p.introductory, 'introductory price at ' || y || ' years: ' || p.amount;
  END LOOP;
  SELECT * INTO p FROM core.fn_price('registration', NULL, DATE '2026-12-02');
  ASSERT p.amount = 370 AND p.vat = 18.50 AND p.list_amount = 480, 'a new term: 370 introductory + 18.50 VAT (388.50), list 480';
  SELECT * INTO p FROM core.fn_price('filing', NULL);         ASSERT p.amount = 100 AND NOT p.introductory, 'filing fee 100';
  SELECT * INTO p FROM core.fn_price('extra_registry', NULL); ASSERT p.amount = 150, 'additional registry 150';
  SELECT * INTO p FROM core.fn_price('watch_only', NULL);     ASSERT p.amount = 150, 'watch-only registry 150';
  SELECT * INTO p FROM core.fn_price('class_add', NULL);      ASSERT p.amount = 100, 'class added 100';
  SELECT * INTO p FROM core.fn_price('filing', NULL, current_date, true); ASSERT p.amount = 0, 'pilot stays free until its terms are ruled';

  -- the offer closed: the list price applies
  UPDATE core.price_list SET rules = jsonb_set(rules, '{introductory,until}', '"2027-03-31"') WHERE version = 2;
  SELECT * INTO p FROM core.fn_price('registration', NULL, DATE '2027-03-31'); ASSERT p.amount = 370 AND p.introductory, 'last day of the offer is still introductory';
  SELECT * INTO p FROM core.fn_price('registration', NULL, DATE '2027-04-01'); ASSERT p.amount = 480 AND p.vat = 24 AND NOT p.introductory, 'after the offer: 480 + 24 VAT (504)';
  SELECT * INTO p FROM core.fn_price('existing_watch', DATE '2032-03-20', DATE '2027-04-01'); ASSERT p.amount = 240, '5 years at list: 240';
  UPDATE core.price_list SET rules = jsonb_set(rules, '{introductory,until}', 'null') WHERE version = 2;
END $$;

-- a new mark: filing fee, then the balance at the certificate
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method)
VALUES ('00000000-0000-0000-0000-0000000059a1', 'owner_individual', '{"en": "Price Test Owner"}', 'AE', now(), 'ai');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000059f1', '00000000-0000-0000-0000-0000000059a1', '{"en": "PRICED"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, mark_text, entry_mode, paid_state)
  SELECT '00000000-0000-0000-0000-0000000059e1', '00000000-0000-0000-0000-0000000059f1', id, '{"en": "PRICED"}', 'new_filing', 'free_new_pending' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000059f2', '00000000-0000-0000-0000-0000000059a1', '{"en": "PRICED OLD"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, registration_no, mark_text, entry_mode, paid_state, expiry_date)
  SELECT '00000000-0000-0000-0000-0000000059e2', '00000000-0000-0000-0000-0000000059f2', id, '590002', '{"en": "PRICED OLD"}', 'existing', 'free_loaded', current_date + 365 * 6 + 100 FROM registry.registry WHERE code = 'AE';
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000059a1', true);

DO $$ DECLARE d record; r core.record; BEGIN
  SELECT * INTO d FROM core.fn_record_due('00000000-0000-0000-0000-0000000059e1');
  ASSERT d."case" = 'filing' AND d.due = 100 AND d.vat = 5 AND d.total = 105 AND d.vat_inclusive, 'new mark owes the filing fee: ' || d.due;
  SELECT * INTO d FROM core.fn_record_due('00000000-0000-0000-0000-0000000059e2');
  ASSERT d."case" = 'existing_watch' AND d.years_remaining = 7 AND d.list_amount = 336 AND d.amount = 259 AND d.credit = 0 AND d.due = 259, 'existing mark pays by years remaining when added: ' || d.due;

  BEGIN
    CALL core.sp_pay('00000000-0000-0000-0000-0000000059e2', '00000000-0000-0000-0000-0000000059a1', 'filing', 100, 5, 'Xeonix Technologies', 'x');
    RAISE EXCEPTION 'an existing mark takes no filing fee';
  EXCEPTION WHEN unique_violation THEN NULL; END;

  CALL core.sp_pay('00000000-0000-0000-0000-0000000059e1', '00000000-0000-0000-0000-0000000059a1', 'filing', 100, 5, 'Xeonix Technologies', 'f1');
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000059e1';
  ASSERT r.paid_state = 'filing_paid' AND r.watch_active_from IS NULL, 'filing fee paid: reminders, no watch';
  BEGIN
    CALL core.sp_pay('00000000-0000-0000-0000-0000000059e1', '00000000-0000-0000-0000-0000000059a1', 'filing', 100, 5, 'Xeonix Technologies', 'f2');
    RAISE EXCEPTION 'a second filing fee should be refused';
  EXCEPTION WHEN unique_violation THEN NULL; END;

  SELECT * INTO d FROM core.fn_record_due('00000000-0000-0000-0000-0000000059e1');
  ASSERT d."case" = 'registration' AND d.amount = 370 AND d.credit = 100 AND d.due = 270 AND d.vat = 13.50 AND d.total = 283.50, 'full price less the 100 already paid: ' || d.due;

  CALL core.sp_certificate_received('00000000-0000-0000-0000-0000000059e1', NULL, current_date, '590001');
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000059e1';
  ASSERT r.paid_state = 'read_only_unpaid', 'at the certificate the balance falls due';
  SELECT * INTO d FROM core.fn_record_due('00000000-0000-0000-0000-0000000059e1');
  ASSERT d.due = 270 AND d.credit = 100, 'the credit still stands at the certificate';

  CALL core.sp_pay('00000000-0000-0000-0000-0000000059e1', '00000000-0000-0000-0000-0000000059a1', 'registration', 270, 13.50, 'Xeonix Technologies', 'r1', 10::smallint);
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000059e1';
  ASSERT r.paid_state = 'paid' AND r.watch_active_from IS NOT NULL, 'paid in full: watch on';
  SELECT * INTO d FROM core.fn_record_due('00000000-0000-0000-0000-0000000059e1');
  ASSERT d.due IS NULL, 'a paid record owes nothing';
END $$;
ROLLBACK;
\echo ALL 0059 TESTS PASSED
