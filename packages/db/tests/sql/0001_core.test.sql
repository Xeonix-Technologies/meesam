-- Behavioural tests for migration 0001 (Data Architecture Section 11: "every function has a test
-- row set in tests/sql"). Run against a database that has the migrations applied:
--   psql -v ON_ERROR_STOP=1 -f packages/db/tests/sql/0001_core.test.sql
-- Everything runs inside one transaction and is rolled back.

BEGIN;
SET client_min_messages = warning;

-- ---------------------------------------------------------------- fixtures (as the migration user)
CREATE TEMP TABLE t (k text PRIMARY KEY, v uuid);

INSERT INTO core.account (id, kind, name, country, verified_at, verification_method)
VALUES ('00000000-0000-0000-0000-00000000000a', 'owner_company', '{"en": "Oro Foods", "ar": "أورو فودز"}', 'AE', now(), 'staff'),
       ('00000000-0000-0000-0000-00000000000b', 'agency_office', '{"en": "Agency Alpha"}', 'AE', now(), 'staff'),
       ('00000000-0000-0000-0000-00000000000c', 'agency_office', '{"en": "Agency Beta"}', 'AE', now(), 'staff');
INSERT INTO t VALUES ('owner', '00000000-0000-0000-0000-00000000000a'), ('alpha', '00000000-0000-0000-0000-00000000000b'), ('beta', '00000000-0000-0000-0000-00000000000c');

INSERT INTO core.app_user (id, account_id, email, name, role) VALUES
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a', 'owner@example.test', 'Owner Admin', 'company_admin'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000000b', 'alpha@example.test', 'Alpha Admin', 'agency_admin'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-00000000000b', 'alpha-agent@example.test', 'Alpha Agent', 'agent');

-- role/kind guard
DO $$ BEGIN
  BEGIN
    INSERT INTO core.app_user (account_id, email, name, role) VALUES ('00000000-0000-0000-0000-00000000000a', 'bad@example.test', 'x', 'agent');
    RAISE EXCEPTION 'expected role guard to fire';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;

-- a test UAE profile (values from the Registry Profiles annex are loaded in Step 3.3; these are test values)
INSERT INTO registry.registry_profile (registry_id, version, effective_from, verified, rules)
SELECT id, 99, DATE '2026-01-01', true, '{
  "calendar": {"timezone": "Asia/Dubai", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":           {"start_event": "published", "days": 30, "verified": true},
    "pay_registration": {"start_event": "accepted", "days": 30, "verified": true},
    "renewal_window":   {"start_event": "registered", "months_before_expiry": 12, "verified": true},
    "expiry":           {"start_event": "registered", "at_expiry": true, "verified": true},
    "grace":            {"start_event": "registered", "months_after_expiry": 6, "verified": false}
  },
  "reminders": {"renewal_window": [6, 3, 1]},
  "status_map": {"published": {"stage": "acceptance_publication_opposition", "label": {"en": "Published", "ar": "منشورة"}}},
  "human_review_waived": false
}'::jsonb FROM registry.registry WHERE code = 'AE';
UPDATE registry.registry SET supported = true WHERE code = 'AE';

-- ---------------------------------------------------------------- owner creates a family and a record
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000a', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000000a1', true);

INSERT INTO core.mark_family (id, owner_account_id, name, mark_type)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', '{"en": "Maysam", "ar": "ميسم"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, mark_text, entry_mode, paid_state)
SELECT '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000f1', id, '123456', DATE '2026-03-01', '{"en": "Maysam", "ar": "ميسم"}', 'new_filing', 'free_new_pending'
  FROM registry.registry WHERE code = 'AE';

DO $$ DECLARE r core.record; BEGIN
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1';
  ASSERT r.stage = 'pre_filing', 'new record starts in pre_filing';
  ASSERT r.mark_text_norm ->> 'en' = 'maysam', 'latin normalised: ' || r.mark_text_norm;
  ASSERT r.mark_text_norm ->> 'ar' = 'ميسم', 'arabic normalised: ' || r.mark_text_norm;
  ASSERT r.phonetic_key IS NOT NULL, 'phonetic key set';
END $$;

-- events move the stage; timers come from the profile
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000000e1', 'filed', DATE '2026-03-01');
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000000e1', 'published', DATE '2026-05-10');
DO $$ DECLARE r core.record; tm core.timer; BEGIN
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1';
  ASSERT r.stage = 'acceptance_publication_opposition', 'stage after published: ' || r.stage;
  ASSERT r.status_label ->> 'ar' = 'منشورة', 'label from profile status_map';
  SELECT * INTO tm FROM core.timer WHERE record_id = r.id AND timer_type = 'oppose';
  ASSERT tm.due_date = DATE '2026-06-09', 'oppose due 30 days after publication, no rollover: ' || tm.due_date;
  ASSERT tm.due_at = TIMESTAMPTZ '2026-06-09 23:59:00+04', 'due_at is 23:59 Dubai: ' || tm.due_at;
  ASSERT tm.source = 'profile';
END $$;

-- a suggested event does not move the stage until confirmed
INSERT INTO core.record_event (id, record_id, event_type, event_date, source)
VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000e1', 'registered', DATE '2026-09-01', 'suggested');
DO $$ DECLARE r core.record; BEGIN
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1';
  ASSERT r.stage = 'acceptance_publication_opposition', 'suggested event must not move the stage';
  ASSERT (SELECT has_suggestions FROM core.v_record_state WHERE record_id = r.id), 'state view flags the suggestion';
END $$;
UPDATE core.record_event SET confirmed_at = now(), confirmed_by_user_id = '00000000-0000-0000-0000-0000000000a1' WHERE id = '00000000-0000-0000-0000-0000000000d1';
DO $$ DECLARE r core.record; n integer; BEGIN
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1';
  ASSERT r.stage = 'registration', 'confirmed registration moves the stage: ' || r.stage;
  ASSERT r.expiry_date = DATE '2036-03-01', 'expiry = filing + 10 years: ' || r.expiry_date;
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = r.id AND timer_type = 'renewal_window') = DATE '2035-03-01', 'renewal window opens 12 months before expiry';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = r.id AND timer_type = 'expiry') = DATE '2036-03-01';
  SELECT count(*) INTO n FROM core.timer WHERE record_id = r.id AND family = 'reminder';
  ASSERT n = 3, 'three renewal reminders (6, 3, 1 months): ' || n;
  ASSERT (SELECT awaiting_user_entry FROM core.timer WHERE record_id = r.id AND timer_type = 'grace'), 'unverified grace clock awaits user entry';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = r.id AND timer_type = 'grace') IS NULL, 'no default supplied for an unverified clock';
  ASSERT (SELECT days_remaining FROM core.v_record_state WHERE record_id = r.id) = (DATE '2036-03-01' - current_date);
END $$;

-- date re-flow: moving the publication date re-creates the oppose timer
UPDATE core.record_event SET event_date = DATE '2026-05-20' WHERE record_id = '00000000-0000-0000-0000-0000000000e1' AND event_type = 'published';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000000e1' AND timer_type = 'oppose' AND state = 'cancelled') = 1;
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000000e1' AND timer_type = 'oppose' AND state = 'open') = DATE '2026-06-19';
END $$;

-- ---------------------------------------------------------------- RLS: agencies see nothing without an appointment
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000b', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000000b1', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 0, 'agency without appointment sees no record';
  ASSERT (SELECT count(*) FROM core.mark_family) = 0, 'nor the family';
  ASSERT (SELECT count(*) FROM core.timer) = 0, 'nor timers';
END $$;

-- owner appoints Alpha on the record
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000a', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000000a1', true);
-- (since 0010 the app role only reads appointments; this fixture is written with the session's own rights)
RESET ROLE;
INSERT INTO core.appointment (id, owner_account_id, agency_account_id, status, requested_by, accepted_at)
VALUES ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', 'accepted', 'owner', now());
INSERT INTO core.appointment_record (appointment_id, record_id) VALUES ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-0000000000e1');
SET LOCAL ROLE meesam_app;

-- Alpha now sees and edits the record; the owner is notified
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000b', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000000b1', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 1, 'appointed agency sees the record';
  ASSERT (SELECT count(*) FROM core.mark_family) = 1, 'and its family';
  ASSERT (SELECT count(*) FROM core.account WHERE id = '00000000-0000-0000-0000-00000000000a') = 1, 'and the counterparty account';
END $$;
UPDATE core.record SET registration_no = 'R-777' WHERE id = '00000000-0000-0000-0000-0000000000e1';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record_edit WHERE record_id = '00000000-0000-0000-0000-0000000000e1' AND account_id = '00000000-0000-0000-0000-00000000000b'
                                                   AND notified_account_id = '00000000-0000-0000-0000-00000000000a') = 1, 'edit logged with the owner as notified party';
END $$;
-- Beta (no appointment) still sees nothing, and cannot update
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000c', true);
DO $$ DECLARE n integer; BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 0, 'Beta sees nothing';
  UPDATE core.record SET registration_no = 'HACK' WHERE id = '00000000-0000-0000-0000-0000000000e1';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Beta cannot update a record it does not hold';
END $$;

-- ending the appointment removes Alpha's access at once
RESET ROLE;
CALL core.sp_end_appointment('00000000-0000-0000-0000-0000000000a9', 'owner');
SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000b', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.record) = 0, 'ended appointment: no access, not even read';
  ASSERT (SELECT count(*) FROM core.appointment WHERE status = 'ended') = 1, 'but the history stays visible';
  ASSERT (SELECT count(*) FROM platform.notification WHERE kind = 'appointment_ended') = 1, 'agency was notified';
END $$;

-- the owner sees the notification raised by Alpha's edit
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000000a', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM platform.notification WHERE kind = 'record_edited') >= 1, 'owner notified of the agency edit';
  ASSERT (SELECT count(*) FROM platform.audit_event WHERE record_id = '00000000-0000-0000-0000-0000000000e1') >= 5, 'audit rows exist for the record';
END $$;

-- ---------------------------------------------------------------- pricing (Business Model Section 7)
RESET ROLE;
DO $$ DECLARE p record; BEGIN
  SELECT * INTO p FROM core.fn_price('registration', DATE '2036-12-01', DATE '2026-12-02'); ASSERT p.amount = 370 AND p.years_remaining = 10, '10y → 370: ' || p.amount;
  SELECT * INTO p FROM core.fn_price('registration', DATE '2032-12-01', DATE '2026-12-02'); ASSERT p.amount = 222 AND p.years_remaining = 6, '6y → 222: ' || p.amount;
  SELECT * INTO p FROM core.fn_price('registration', DATE '2030-12-01', DATE '2026-12-02'); ASSERT p.amount = 150 AND p.years_remaining = 4, '4y → 150 floor: ' || p.amount;
  SELECT * INTO p FROM core.fn_price('registration', DATE '2027-06-01', DATE '2026-12-02'); ASSERT p.amount = 150 AND p.years_remaining = 1, '<4y → 150: ' || p.amount;
  SELECT * INTO p FROM core.fn_price('registration', DATE '2032-01-15', DATE '2026-12-02'); ASSERT p.years_remaining = 6, 'part year counts as full: ' || p.years_remaining;
  SELECT * INTO p FROM core.fn_price('extra_registry', NULL); ASSERT p.amount = 100;
  SELECT * INTO p FROM core.fn_price('watch_only', NULL); ASSERT p.amount = 100;
  SELECT * INTO p FROM core.fn_price('class_add', NULL); ASSERT p.amount = 100;
  SELECT * INTO p FROM core.fn_price('registration', DATE '2036-12-01', DATE '2026-12-02', true); ASSERT p.amount = 0 AND p.vat = 0, 'pilot: everything free';
  SELECT * INTO p FROM core.fn_price('registration', DATE '2032-12-01', DATE '2026-12-02'); ASSERT p.vat = 11.10, 'VAT 5% on 222 = 11.10: ' || p.vat;
END $$;

-- payment: once, then refused
CALL core.sp_pay('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', 'registration', 370, 18.50, 'Wahaat Investment L.L.C.', 'test-ref');
DO $$ DECLARE r core.record; BEGIN
  SELECT * INTO r FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1';
  ASSERT r.paid_state = 'paid' AND r.watch_active_from IS NOT NULL, 'paid and watch switched on';
  BEGIN
    CALL core.sp_pay('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', 'registration', 370, 18.50, 'Wahaat Investment L.L.C.', 'dup');
    RAISE EXCEPTION 'second payment should be refused';
  EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;

-- ---------------------------------------------------------------- owner pass: single use, 30 days
INSERT INTO core.owner_pass (record_id, issued_by_account_id, token_hash)
VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000b', digest('secret-token', 'sha256'));
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method)
VALUES ('00000000-0000-0000-0000-00000000000d', 'owner_individual', '{"en": "New Owner"}', 'AE', now(), 'ai');
CALL core.sp_redeem_pass('secret-token', '00000000-0000-0000-0000-00000000000d');
DO $$ BEGIN
  ASSERT (SELECT owner_account_id FROM core.mark_family WHERE id = '00000000-0000-0000-0000-0000000000f1') = '00000000-0000-0000-0000-00000000000d', 'family moved to the redeeming owner';
  BEGIN
    CALL core.sp_redeem_pass('secret-token', '00000000-0000-0000-0000-00000000000d');
    RAISE EXCEPTION 'pass must be single use';
  EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
END $$;

-- ---------------------------------------------------------------- quotes: only agency_admin sends; selecting declines siblings
INSERT INTO core.quote_request (id, owner_account_id, record_id) VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-0000000000e1');
INSERT INTO core.quote_request_recipient (quote_request_id, agency_account_id) VALUES
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000b'), ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000c');
DO $$ BEGIN ASSERT (SELECT sent_to_count FROM core.quote_request WHERE id = '00000000-0000-0000-0000-0000000000c1') = 2, 'sent_to_count maintained'; END $$;
INSERT INTO core.quote (id, quote_request_id, agency_account_id, amount) VALUES
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000b', 1500),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000c', 1200);
DO $$ BEGIN
  BEGIN
    UPDATE core.quote SET status = 'sent', sent_by_user_id = '00000000-0000-0000-0000-0000000000b2' WHERE id = '00000000-0000-0000-0000-0000000000c2';
    RAISE EXCEPTION 'an agent must not send a quote';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
UPDATE core.quote SET status = 'sent', sent_by_user_id = '00000000-0000-0000-0000-0000000000b1' WHERE id = '00000000-0000-0000-0000-0000000000c2';
UPDATE core.quote SET status = 'sent', sent_by_user_id = '00000000-0000-0000-0000-0000000000b1' WHERE id = '00000000-0000-0000-0000-0000000000c3';
CALL core.sp_select_quote('00000000-0000-0000-0000-0000000000c2');
DO $$ BEGIN
  ASSERT (SELECT status FROM core.quote WHERE id = '00000000-0000-0000-0000-0000000000c3') = 'declined', 'sibling declined';
  ASSERT (SELECT count(*) FROM core.appointment WHERE owner_account_id = '00000000-0000-0000-0000-00000000000d' AND agency_account_id = '00000000-0000-0000-0000-00000000000b' AND status = 'requested') = 1, 'appointment requested';
END $$;

-- ---------------------------------------------------------------- POA state
INSERT INTO core.document (record_id, doc_type, object_key, file_name, sha256, valid_until)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'POA', '123456_1_010326_POA.pdf', 'poa.pdf', digest('x', 'sha256'), current_date - 1);
DO $$ BEGIN ASSERT (SELECT poa_state FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1') = 'expired', 'expired POA'; END $$;
INSERT INTO core.document (record_id, doc_type, object_key, file_name, sha256, valid_until)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'POA', '123456_2_010326_POA.pdf', 'poa2.pdf', digest('y', 'sha256'), current_date + 365);
DO $$ BEGIN ASSERT (SELECT poa_state FROM core.record WHERE id = '00000000-0000-0000-0000-0000000000e1') = 'present', 'valid POA present'; END $$;

-- ---------------------------------------------------------------- job queue
DO $$ DECLARE j platform.job; id1 uuid; id2 uuid; BEGIN
  id1 := platform.enqueue_job('timers.nightly', '{}', now(), 'timers.nightly');
  id2 := platform.enqueue_job('timers.nightly', '{}', now(), 'timers.nightly');
  ASSERT id2 IS NULL, 'dedupe key prevents a duplicate queued job';
  SELECT * INTO j FROM platform.claim_jobs('worker-1', 5);
  ASSERT j.id = id1 AND j.status = 'running' AND j.attempts = 1, 'claimed';
  ASSERT NOT EXISTS (SELECT 1 FROM platform.claim_jobs('worker-2', 5)), 'a running job is not claimed twice';
  PERFORM platform.fail_job(id1, 'boom');
  SELECT * INTO j FROM platform.job WHERE id = id1;
  ASSERT j.status = 'queued' AND j.run_at > now(), 'failed job requeued with back-off';
  UPDATE platform.job SET run_at = now() WHERE id = id1;
  SELECT * INTO j FROM platform.claim_jobs('worker-1', 5);
  PERFORM platform.complete_job(id1);
  ASSERT (SELECT status FROM platform.job WHERE id = id1) = 'done';
END $$;

-- ---------------------------------------------------------------- normaliser
DO $$ DECLARE a record; b record; BEGIN
  SELECT * INTO a FROM watch.fn_normalise_mark('{"ar": "مَيْسَم", "en": "MAYSAM!"}');
  ASSERT a.norm ->> 'ar' = 'ميسم', 'diacritics stripped: ' || a.norm;
  ASSERT a.norm ->> 'en' = 'maysam', 'case and punctuation: ' || a.norm;
  SELECT * INTO b FROM watch.fn_normalise_mark('{"ar": "ميسمة", "en": "Maisam"}');
  ASSERT split_part(a.phonetic, '|', 1) = split_part(b.phonetic, '|', 1), 'Maysam ~ Maisam share a Latin key: ' || a.phonetic || ' vs ' || b.phonetic;
END $$;

-- ---------------------------------------------------------------- partitions exist per registry
DO $$ BEGIN
  ASSERT to_regclass('watch.published_mark_ae') IS NOT NULL, 'per-registry partition for AE';
  ASSERT to_regclass('watch.published_mark_ae_' || extract(year FROM current_date)::text) IS NOT NULL, 'yearly sub-partition';
  ASSERT to_regclass('platform.audit_event_' || to_char(current_date, 'YYYY_MM')) IS NOT NULL, 'monthly audit partition';
END $$;

-- prospect schema is closed to the app role
SET LOCAL ROLE meesam_app;
DO $$ BEGIN
  BEGIN
    PERFORM count(*) FROM prospect.prospect_party;
    RAISE EXCEPTION 'app role must not read prospect data';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

SELECT 'ALL 0001 TESTS PASSED' AS result;
ROLLBACK;
