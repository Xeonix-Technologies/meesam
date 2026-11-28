-- Tests for migration 0104: a trademark loaded in bulk waits for activation; the basket.
-- What activation asks for is as amended by 0105 and 0106: the mark's image, and for a registered mark its
-- certificate, read, with the expiry date of the record.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-000000104a00', 'agency_office', '{"en": "Agency 104"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-000000104b00', 'agency_office', '{"en": "Other agency 104"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES
  ('00000000-0000-0000-0000-000000104a01', '00000000-0000-0000-0000-000000104a00', 'adm@x104.test', 'Adm', 'agency_admin', 'active'),
  ('00000000-0000-0000-0000-000000104a02', '00000000-0000-0000-0000-000000104a00', 'view@x104.test', 'View', 'viewer', 'active'),
  ('00000000-0000-0000-0000-000000104b01', '00000000-0000-0000-0000-000000104b00', 'oth@x104.test', 'Oth', 'agency_admin', 'active');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-000000104f01', '00000000-0000-0000-0000-000000104a00', '{"en": "Loaded"}', 'word'),
  ('00000000-0000-0000-0000-000000104f02', '00000000-0000-0000-0000-000000104a00', '{"en": "Single"}', 'word'),
  ('00000000-0000-0000-0000-000000104f03', '00000000-0000-0000-0000-000000104a00', '{"en": "Loaded bare"}', 'word');
-- a bulk-loaded record starts not active even when the statement says otherwise; one added singly is active
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, registration_no, entry_mode, paid_state, mark_text, expiry_date, activated_at, activation_requested_at)
  SELECT '00000000-0000-0000-0000-000000104e01', '00000000-0000-0000-0000-000000104f01', g.id, 'X104-1', 'R104-1', 'bulk_import', 'free_loaded', '{"en": "Loaded"}', current_date + 2000, now(), now()
    FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-000000104e02', '00000000-0000-0000-0000-000000104f02', g.id, 'X104-2', 'existing', 'free_loaded', '{"en": "Single"}' FROM registry.registry g WHERE g.code = 'AE';
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, entry_mode, paid_state, mark_text)
  SELECT '00000000-0000-0000-0000-000000104e03', '00000000-0000-0000-0000-000000104f03', g.id, 'X104-3', 'bulk_import', 'free_loaded', '{"en": "Loaded bare"}' FROM registry.registry g WHERE g.code = 'AE';
DO $$ BEGIN
  ASSERT (SELECT activated_at IS NULL AND activation_requested_at IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000104e01'), 'loaded in bulk: not active, not in the basket';
  ASSERT (SELECT activated_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000104e02'), 'added singly: active';
  ASSERT NOT core.fn_record_watched('00000000-0000-0000-0000-000000104e01'), 'not active: not watched';
  ASSERT core.fn_record_watched('00000000-0000-0000-0000-000000104e02') = COALESCE((core.fn_price_list_rules() ->> 'pilot_all_free')::boolean, false), 'active: watched while the pilot is free';
END $$;

-- reminders: the same clock on both records; only the active one is reminded
DELETE FROM core.timer WHERE record_id IN ('00000000-0000-0000-0000-000000104e01', '00000000-0000-0000-0000-000000104e02');
INSERT INTO core.timer (id, record_id, family, timer_type, due_date, source, created_at) VALUES
  ('00000000-0000-0000-0000-000000104101', '00000000-0000-0000-0000-000000104e01', 'statutory', 'oppose', DATE '2027-01-20', 'profile', TIMESTAMPTZ '2026-12-21 08:00+04'),
  ('00000000-0000-0000-0000-000000104102', '00000000-0000-0000-0000-000000104e02', 'statutory', 'oppose', DATE '2027-01-20', 'profile', TIMESTAMPTZ '2026-12-21 08:00+04');
DO $$ BEGIN
  PERFORM core.fn_reminders_materialise(TIMESTAMPTZ '2027-01-10 12:00+04');
  ASSERT (SELECT count(*) FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000104102') > 0, 'the active record is reminded';
  ASSERT (SELECT count(*) FROM platform.notification WHERE timer_id = '00000000-0000-0000-0000-000000104101') = 0, 'the record not yet active is not';
END $$;

CREATE TEMP TABLE t104 (k text PRIMARY KEY, n integer); GRANT ALL ON t104 TO meesam_app;
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104a01', true);
-- the app role cannot activate by writing the column
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN UPDATE core.record SET activated_at = now() WHERE id = '00000000-0000-0000-0000-000000104e01'; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no direct activation';
  denied := false;
  BEGIN UPDATE core.record SET activation_requested_at = now() WHERE id = '00000000-0000-0000-0000-000000104e01'; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'no direct request';
END $$;
-- not ready: no image, no document
INSERT INTO t104 VALUES ('bare', core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000104e01']::uuid[]));
DO $$ DECLARE c record; BEGIN
  ASSERT (SELECT n FROM t104 WHERE k = 'bare') = 0, 'a registered mark without image and certificate is passed over';
  ASSERT (SELECT NOT has_image AND needs_certificate AND NOT has_certificate AND NOT ready FROM core.fn_activation_needs('00000000-0000-0000-0000-000000104e01')), 'and says what is missing';
  SELECT * INTO c FROM core.fn_activation_counts();
  ASSERT c.waiting = 2 AND c.ready = 0 AND c.in_basket = 0, format('two wait, none ready: %s %s %s', c.waiting, c.ready, c.in_basket);
END $$;
RESET ROLE;
-- the image and a certificate arrive
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000104d01', '00000000-0000-0000-0000-000000104e01', 'IMG', 'AE/x104_img.png', 'm.png', 'image/png', 10, decode('00', 'hex'), '00000000-0000-0000-0000-000000104a00');
UPDATE core.record SET mark_image_doc_id = '00000000-0000-0000-0000-000000104d01' WHERE id = '00000000-0000-0000-0000-000000104e01';
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104a01', true);
INSERT INTO t104 VALUES ('imageOnly', core.fn_activation_request());
RESET ROLE;
INSERT INTO core.document (id, record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_account_id) VALUES
  ('00000000-0000-0000-0000-000000104d02', '00000000-0000-0000-0000-000000104e01', 'ORC', 'AE/x104_orc.pdf', 'c.pdf', 'application/pdf', 10, decode('01', 'hex'), '00000000-0000-0000-0000-000000104a00');
-- 0106: the certificate has been read and its expiry date is the record's
INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, registration_no, confidence)
  VALUES ('00000000-0000-0000-0000-000000104d02', '00000000-0000-0000-0000-000000104e01', 'read', current_date + 2000, 'R104-1', 0.95);

-- a Viewer and another account cannot request
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104a02', true);
DO $$ DECLARE denied boolean := false; BEGIN
  BEGIN PERFORM core.fn_activation_request(); EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'a Viewer does not activate';
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104b00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104b01', true);
INSERT INTO t104 VALUES ('stranger', core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000104e01']::uuid[]));

SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104a01', true);
DO $$ DECLARE c record; BEGIN
  ASSERT (SELECT n FROM t104 WHERE k = 'imageOnly') = 0, 'for a registered mark the image alone is not enough';
  ASSERT (SELECT n FROM t104 WHERE k = 'stranger') = 0, 'another account puts nothing in the basket';
  SELECT * INTO c FROM core.fn_activation_counts();
  ASSERT c.waiting = 2 AND c.ready = 1, 'one of the two is ready now';
END $$;
INSERT INTO t104 VALUES ('all', core.fn_activation_request());
DO $$ DECLARE c record; b record; BEGIN
  ASSERT (SELECT n FROM t104 WHERE k = 'all') = 1, 'the ready one goes in the basket';
  SELECT * INTO c FROM core.fn_activation_counts();
  ASSERT c.waiting = 1 AND c.ready = 0 AND c.in_basket = 1, 'one waits, one in the basket';
  SELECT * INTO b FROM core.fn_basket();
  ASSERT b.record_id = '00000000-0000-0000-0000-000000104e01' AND b.number = 'R104-1' AND b.registry_code = 'AE', 'the basket lists it';
  ASSERT b.amount > 0 AND b.total >= b.due AND b.years_remaining >= 5, format('with the price list''s price for the years remaining: %s for %s years', b.amount, b.years_remaining);
  ASSERT NOT core.fn_record_watched('00000000-0000-0000-0000-000000104e01'), 'in the basket is still not watched';
  -- out and in again
  ASSERT core.fn_activation_withdraw('00000000-0000-0000-0000-000000104e01'), 'taken out';
  ASSERT (SELECT count(*) FROM core.fn_basket()) = 0, 'the basket is empty';
  ASSERT core.fn_activation_request(ARRAY['00000000-0000-0000-0000-000000104e01']::uuid[]) = 1, 'and in again';
END $$;
-- another account sees an empty basket and checks out nothing
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104b00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104b01', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.fn_basket()) = 0, 'another account''s basket is its own';
  IF core.fn_basket_free() THEN ASSERT core.fn_basket_checkout() = 0, 'and its checkout touches nothing'; END IF;
END $$;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-000000104a00', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-000000104a01', true);
DO $$ DECLARE n integer; refused boolean := false; BEGIN
  IF core.fn_basket_free() THEN
    n := core.fn_basket_checkout();
    ASSERT n = 1, 'checkout activates what is in the basket';
    ASSERT (SELECT activated_at IS NOT NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000104e01'), 'active now';
    ASSERT (SELECT activated_at IS NULL FROM core.record WHERE id = '00000000-0000-0000-0000-000000104e03'), 'the one not in the basket stays as it was';
    ASSERT core.fn_record_watched('00000000-0000-0000-0000-000000104e01'), 'and watched';
    ASSERT (SELECT count(*) FROM core.fn_basket()) = 0, 'the basket is empty after checkout';
  ELSE
    BEGIN PERFORM core.fn_basket_checkout(); EXCEPTION WHEN feature_not_supported THEN refused := true; END;
    ASSERT refused, 'with a price due and no payment provider, checkout refuses';
  END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
  IF core.fn_basket_free() THEN
    ASSERT (SELECT count(*) FROM platform.job WHERE kind = 'watch.compare_record' AND payload ->> 'record_id' = '00000000-0000-0000-0000-000000104e01') >= 1, 'the activated record is queued for comparison';
    ASSERT (SELECT count(*) FROM platform.audit_event WHERE table_name = 'record' AND row_id = '00000000-0000-0000-0000-000000104e01' AND action = 'UPDATE'
              AND account_id = '00000000-0000-0000-0000-000000104a00' AND after ->> 'activated_at' IS NOT NULL) >= 1, 'the activation is audited with the account that did it';
  END IF;
  -- the pilot ended: a price is due, no provider is connected, checkout refuses
  UPDATE core.price_list SET rules = rules || '{"pilot_all_free": false}'::jsonb;
  ASSERT NOT core.fn_basket_free(), 'not free once the pilot rule is off';
  ASSERT NOT core.fn_record_watched('00000000-0000-0000-0000-000000104e02'), 'an unpaid record is no longer watched then (as before 0104)';
END $$;
ROLLBACK;
\echo ALL 0104 TESTS PASSED
