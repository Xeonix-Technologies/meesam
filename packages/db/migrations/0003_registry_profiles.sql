-- =============================================================================
-- Meesam — migration 0003: registry profiles, publication sources, Nice headings (Step 3.3)
-- Source of truth: "MSM — Registry Profiles and Deadlines v0.1" (annex to MSM-PRD-02 v1.2,
-- locked 12 Nov 2026), Sections 1–4. Every clock carries the annex's State: verified=true only
-- where the annex says Verified; an unverified clock creates a timer that waits for the user's
-- entry and computes no date (System Description item 44). Confirming a value is a DATA update
-- (a new registry_profile version), not a code change (annex preamble).
-- Ruled 12 Nov 2026: a registry opens in Meesam (registry.supported = true) only when every
-- value in its rows is Verified and its re-use rule is confirmed. Today that is the UAE alone.
-- =============================================================================
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Timer engine refinements needed by the annex (replaces the 0001 definition)
--    * reminders may be relative to expiry (renewal window) or to the clock's own due date
--      (US Section 8 window): {"before": "expiry"|"due", "months": [...]}; a bare array keeps the
--      0001 meaning (months before expiry).
--    * "months" counts from the start event (used for anniversary windows: 72 months = 6th anniversary).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_timers_for_event(p_event_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  e core.record_event; r core.record; prof registry.registry_profile; tz text;
  k text; spec jsonb; v_due date; v_verified boolean; n integer := 0; base date; months integer;
  rem jsonb; rem_base date; rem_months jsonb;
BEGIN
  SELECT * INTO e FROM core.record_event WHERE id = p_event_id;
  IF e.source = 'suggested' AND e.confirmed_at IS NULL THEN RETURN 0; END IF;
  SELECT * INTO r FROM core.record WHERE id = e.record_id;
  prof := registry.fn_current_profile(r.registry_id, e.event_date);
  IF prof.id IS NULL THEN RETURN 0; END IF;
  tz := prof.rules -> 'calendar' ->> 'timezone';

  -- Registration sets expiry from the term rule (filing_date + N years, or registration_date for US/CN).
  IF e.event_type = 'registered' AND prof.rules ? 'term' THEN
    base := CASE prof.rules -> 'term' ->> 'from' WHEN 'registration_date' THEN e.event_date ELSE COALESCE(r.filing_date, e.event_date) END;
    v_due := (base + make_interval(years => COALESCE((prof.rules -> 'term' ->> 'years')::integer, 10)))::date;
    UPDATE core.record SET registration_date = COALESCE(registration_date, e.event_date), expiry_date = v_due WHERE id = r.id;
    r.expiry_date := v_due;
  END IF;

  FOR k, spec IN SELECT key, value FROM jsonb_each(prof.rules -> 'timers') LOOP
    CONTINUE WHEN spec ->> 'start_event' IS DISTINCT FROM e.event_type::text;
    v_verified := COALESCE((spec ->> 'verified')::boolean, prof.verified);
    IF NOT v_verified THEN
      INSERT INTO core.timer (record_id, event_id, family, timer_type, source, awaiting_user_entry)
      VALUES (r.id, e.id, 'statutory', k, 'user_entered', true);
      n := n + 1; CONTINUE;
    END IF;
    IF spec ? 'days' THEN
      v_due := e.event_date + (spec ->> 'days')::integer;
    ELSIF spec ? 'months' THEN
      v_due := (e.event_date + make_interval(months => (spec ->> 'months')::integer))::date;
    ELSIF spec ? 'months_before_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := (r.expiry_date - make_interval(months => (spec ->> 'months_before_expiry')::integer))::date;
    ELSIF spec ? 'months_after_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := (r.expiry_date + make_interval(months => (spec ->> 'months_after_expiry')::integer))::date;
    ELSIF spec ? 'at_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := r.expiry_date;
    ELSE
      CONTINUE;
    END IF;
    INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
    VALUES (r.id, e.id, 'statutory', k, v_due, core.fn_due_at(v_due, tz), 'profile');
    n := n + 1;

    rem := prof.rules -> 'reminders' -> k;
    IF rem IS NOT NULL THEN
      IF jsonb_typeof(rem) = 'array' THEN
        rem_base := r.expiry_date; rem_months := rem;
      ELSE
        rem_base := CASE rem ->> 'before' WHEN 'due' THEN v_due ELSE r.expiry_date END;
        rem_months := rem -> 'months';
      END IF;
      IF rem_base IS NOT NULL THEN
        FOR months IN SELECT (x)::integer FROM jsonb_array_elements_text(rem_months) x LOOP
          INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
          VALUES (r.id, e.id, 'reminder', format('%s_reminder_%sm', k, months),
                  (rem_base - make_interval(months => months))::date,
                  core.fn_due_at((rem_base - make_interval(months => months))::date, tz), 'profile');
          n := n + 1;
        END LOOP;
      END IF;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- A record whose events pre-date the first profile version (existing marks loaded with their
-- history) still gets the rules in force: fall back to the earliest version.
CREATE OR REPLACE FUNCTION registry.fn_current_profile(p_registry_id uuid, p_as_of date DEFAULT current_date)
RETURNS registry.registry_profile LANGUAGE sql STABLE AS $$
  SELECT * FROM (
    SELECT p.* FROM registry.registry_profile p
     WHERE p.registry_id = p_registry_id AND p.effective_from <= p_as_of
     ORDER BY p.effective_from DESC, p.version DESC LIMIT 1
  ) cur
  UNION ALL
  SELECT * FROM (
    SELECT p.* FROM registry.registry_profile p
     WHERE p.registry_id = p_registry_id
     ORDER BY p.effective_from ASC, p.version ASC LIMIT 1
  ) first_version
  LIMIT 1
$$;

-- -----------------------------------------------------------------------------
-- 2. Profiles, version 1 per registry (annex Sections 1, 3, 4)
--    Shared GCC block: GCC Trademark Law, national implementation; verified per country.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE _profile (code text PRIMARY KEY, verified boolean, rules jsonb);

-- United Arab Emirates — Verified (MoET meeting 27 Oct 2026; agent 27–29 Oct 2026)
INSERT INTO _profile VALUES ('AE', true, '{
  "calendar": {"timezone": "Asia/Dubai", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":            {"start_event": "published", "days": 30, "verified": true, "extension": null,
                          "consequence": {"en": "Opposition window closes; the application proceeds to acceptance."}},
    "counterstatement":  {"start_event": "opposed", "days": 30, "verified": true, "extension": null},
    "pay_registration":  {"start_event": "accepted", "days": 30, "verified": true,
                          "extension": {"note": {"en": "None; monthly penalties accrue after the due date."}}},
    "appeal":            {"start_event": "refused", "days": 30, "verified": true},
    "priority_document": {"start_event": "filed", "months": 6, "verified": true},
    "renewal_window":    {"start_event": "registered", "months_before_expiry": 12, "verified": true},
    "expiry":            {"start_event": "registered", "at_expiry": true, "verified": true},
    "grace":             {"start_event": "registered", "months_after_expiry": 6, "verified": true,
                          "extension": null,
                          "consequence": {"en": "Cancellation after the grace period; three-year bar on third-party filings for the same mark (agent material, to confirm with MoET)."}}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3],
  "status_map": {},
  "human_review_waived": false,
  "filing": {
    "who_may_file": {"en": "The owner directly, or a licensed agent."},
    "foreign_applicant": {"en": "Must file through a local agent."},
    "nice_edition": "13th (2026); class headings accepted",
    "classes_per_application": {"en": "Several; fee per class; registered SMEs pay 50%."},
    "power_of_attorney": {"en": "Per client, single or general, sub-delegable; notarised (UAE owner) or legalised (foreign)."},
    "status_lookup": {"en": "Yes, by application or registration number."},
    "fee_basis": "per_class"
  },
  "publication_streams": ["national_bulletin", "madrid_designations"],
  "source": {"state": "Verified", "notes": "MoET meeting 27 Oct 2026; agent 27–29 Oct 2026; grace and appeal from agent training material, to confirm with MoET"}
}'::jsonb);

-- United Kingdom — Unverified
INSERT INTO _profile VALUES ('GB', false, '{
  "calendar": {"timezone": "Europe/London", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":         {"start_event": "published", "months": 2, "verified": false,
                       "extension": {"months": 1, "note": {"en": "+1 month on a notice of threatened opposition (TM7A)."}}},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 6, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "late_renewal":   {"start_event": "registered", "months_after_expiry": 6, "verified": false,
                       "extension": {"months": 6, "note": {"en": "Restoration possible for a further 6 months."}}}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3],
  "status_map": {},
  "human_review_waived": true,
  "filing": {
    "who_may_file": {"en": "The owner or a representative."},
    "foreign_applicant": {"en": "Needs an address for service in the UK, Gibraltar or the Channel Islands."},
    "nice_edition": "Current edition",
    "classes_per_application": {"en": "Several; fee per additional class."},
    "power_of_attorney": {"en": "Not generally required."},
    "status_lookup": {"en": "Yes, online register."},
    "fee_basis": "per_class"
  },
  "publication_streams": ["national_bulletin"],
  "source": {"state": "Unverified", "notes": "Entered from general knowledge; UK IPO published rules to confirm"}
}'::jsonb);

-- European Union — Unverified
INSERT INTO _profile VALUES ('EM', false, '{
  "calendar": {"timezone": "Europe/Madrid", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":         {"start_event": "published", "months": 3, "verified": false, "extension": null,
                       "consequence": {"en": "Cooling-off after filing the opposition is a separate step."}},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 6, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "late_renewal":   {"start_event": "registered", "months_after_expiry": 6, "verified": false,
                       "consequence": {"en": "25% surcharge."}}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3],
  "status_map": {},
  "human_review_waived": true,
  "filing": {
    "who_may_file": {"en": "The owner or a representative."},
    "foreign_applicant": {"en": "Applicants outside the EEA must be represented by a professional representative for proceedings beyond filing."},
    "nice_edition": "Current edition",
    "classes_per_application": {"en": "Several; one class in the base fee, fees for the second and each further class."},
    "power_of_attorney": {"en": "Not generally required."},
    "status_lookup": {"en": "Yes, online register (eSearch)."},
    "fee_basis": "per_class"
  },
  "publication_streams": ["national_bulletin"],
  "source": {"state": "Unverified", "notes": "EUIPO published rules and open-data terms to confirm"}
}'::jsonb);

-- United States — partly verified (maintenance clocks from certificates, item 43)
INSERT INTO _profile VALUES ('US', false, '{
  "calendar": {"timezone": "America/New_York", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "registration_date"},
  "timers": {
    "oppose":                  {"start_event": "published", "days": 30, "verified": false,
                                "extension": {"note": {"en": "Extensions available up to a maximum of 180 days from publication."}}},
    "section8_declaration":    {"start_event": "registered", "months": 72, "verified": true,
                                "extension": {"months": 6, "note": {"en": "6-month grace with surcharge."}},
                                "consequence": {"en": "Window opens at the 5th anniversary of registration and closes at the 6th."}},
    "section8_9_renewal":      {"start_event": "registered", "at_expiry": true, "verified": true,
                                "extension": {"months": 6, "note": {"en": "6-month grace with surcharge; then every 10 years."}}},
    "expiry":                  {"start_event": "registered", "at_expiry": true, "verified": true}
  },
  "reminders": {
    "section8_declaration": {"before": "due", "months": [12, 6, 3, 1]},
    "section8_9_renewal":   {"before": "due", "months": [12, 6, 3, 1]}
  },
  "watch_alert_reminders_days": [10, 3],
  "status_map": {},
  "human_review_waived": false,
  "madrid": {"renewal": {"en": "Madrid-based registrations renew at WIPO, 10 years from the international registration date (central renewal)."}},
  "filing": {
    "who_may_file": {"en": "The owner or an attorney."},
    "foreign_applicant": {"en": "Foreign-domiciled applicants must be represented by a US-licensed attorney."},
    "nice_edition": "Current edition",
    "classes_per_application": {"en": "Several; fee per class."},
    "power_of_attorney": {"en": "Not required."},
    "status_lookup": {"en": "Yes, by serial or registration number (TSDR)."},
    "fee_basis": "per_class"
  },
  "publication_streams": ["uspto_tmog"],
  "source": {"state": "Partly verified", "notes": "Section 8 / 8-9 windows and term verified from USPTO certificates (item 43); opposition and filing rules unverified"}
}'::jsonb);

-- GCC block (GCC Trademark Law, national implementation) — SA, OM, KW, QA, BH
INSERT INTO _profile
SELECT c.code, false, jsonb_build_object(
  'calendar', jsonb_build_object('timezone', c.tz, 'weekend', '[5, 6]'::jsonb, 'holidays', '[]'::jsonb),
  'term', '{"years": 10, "from": "filing_date"}'::jsonb,
  'timers', jsonb_build_object(
    'oppose',         jsonb_build_object('start_event', 'published', 'days', 60, 'verified', c.oppose_verified,
                                         'extension', jsonb_build_object('note', jsonb_build_object('en', 'To confirm.'))),
    'renewal_window', '{"start_event": "registered", "months_before_expiry": 12, "verified": false}'::jsonb,
    'expiry',         '{"start_event": "registered", "at_expiry": true, "verified": false}'::jsonb,
    'grace',          '{"start_event": "registered", "months_after_expiry": 6, "verified": false, "consequence": {"en": "With surcharge."}}'::jsonb),
  'reminders', '{"renewal_window": {"before": "expiry", "months": [6, 3, 1]}}'::jsonb,
  'watch_alert_reminders_days', '[10, 3]'::jsonb,
  'status_map', '{}'::jsonb,
  'human_review_waived', false,
  'filing', jsonb_build_object(
    'who_may_file', '{"en": "The owner or a licensed agent."}'::jsonb,
    'foreign_applicant', '{"en": "Through a local agent."}'::jsonb,
    'nice_edition', 'Current edition',
    'classes_per_application', jsonb_build_object('en', c.classes),
    'power_of_attorney', '{"en": "Legalised."}'::jsonb,
    'status_lookup', jsonb_build_object('en', c.lookup),
    'fee_basis', 'per_class'),
  'publication_streams', '["national_bulletin"]'::jsonb,
  'source', jsonb_build_object('state', c.state, 'notes', c.notes))
FROM (VALUES
  ('SA', 'Asia/Riyadh',  false, 'Several (to confirm).', 'Yes, SAIP portal.', 'Unverified', 'GCC law; Madrid membership to confirm'),
  ('OM', 'Asia/Muscat',  false, 'To confirm.',           'To confirm.',       'Unverified', 'GCC law'),
  ('KW', 'Asia/Kuwait',  false, 'Single-class practice (to confirm).', 'To confirm.', 'Unverified', 'GCC law; Madrid membership to confirm'),
  ('QA', 'Asia/Qatar',   true,  'To confirm.',           'To confirm.',       'Partly verified', 'Opposition 60 days verified 12 Nov 2026 (Hukoomi portal, supplied by the Founder; confirm against the Ministry''s rules); renewal and grace unverified'),
  ('BH', 'Asia/Bahrain', false, 'To confirm.',           'To confirm.',       'Unverified', 'GCC law')
) AS c(code, tz, oppose_verified, classes, lookup, state, notes);

-- Second wave — TR, IN, CN, EG, JO (all Unverified; profiled so the rows exist, never opened)
INSERT INTO _profile VALUES ('TR', false, '{
  "calendar": {"timezone": "Europe/Istanbul", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":         {"start_event": "published", "months": 2, "verified": false},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 6, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "grace":          {"start_event": "registered", "months_after_expiry": 6, "verified": false, "consequence": {"en": "With surcharge."}}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3], "status_map": {}, "human_review_waived": false,
  "filing": {"who_may_file": {"en": "The owner or a registered attorney."}, "foreign_applicant": {"en": "Through a registered Turkish trademark attorney."},
             "nice_edition": "Current edition", "classes_per_application": {"en": "Several; fee per class."}, "power_of_attorney": {"en": "To confirm."},
             "status_lookup": {"en": "Yes, online."}, "fee_basis": "per_class"},
  "publication_streams": ["national_bulletin"], "source": {"state": "Unverified", "notes": "Second wave, proposed first"}
}'::jsonb);
INSERT INTO _profile VALUES ('IN', false, '{
  "calendar": {"timezone": "Asia/Kolkata", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":         {"start_event": "published", "months": 4, "verified": false},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 12, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "grace":          {"start_event": "registered", "months_after_expiry": 6, "verified": false, "consequence": {"en": "With surcharge; restoration after."}}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3], "status_map": {}, "human_review_waived": false,
  "filing": {"who_may_file": {"en": "The owner or a registered agent / attorney."}, "foreign_applicant": {"en": "Needs an address for service in India."},
             "nice_edition": "Current edition", "classes_per_application": {"en": "Several; fee per class."}, "power_of_attorney": {"en": "Power of attorney (Form TM-M)."},
             "status_lookup": {"en": "Yes, online."}, "fee_basis": "per_class"},
  "publication_streams": ["national_bulletin"], "source": {"state": "Unverified", "notes": "Second wave, proposed second"}
}'::jsonb);
INSERT INTO _profile VALUES ('CN', false, '{
  "calendar": {"timezone": "Asia/Shanghai", "weekend": [6, 0], "holidays": []},
  "term": {"years": 10, "from": "registration_date"},
  "timers": {
    "oppose":         {"start_event": "published", "months": 3, "verified": false, "consequence": {"en": "Counted from publication of preliminary approval in the Trademark Gazette."}},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 12, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "grace":          {"start_event": "registered", "months_after_expiry": 6, "verified": false}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3], "status_map": {}, "human_review_waived": false,
  "filing": {"who_may_file": {"en": "The owner (domestic) or a licensed agency."}, "foreign_applicant": {"en": "Must file through a licensed Chinese trademark agency."},
             "nice_edition": "Current edition, with China''s sub-class system", "classes_per_application": {"en": "Several; fee per class, extra above 10 items."},
             "power_of_attorney": {"en": "Signed power of attorney."}, "status_lookup": {"en": "Yes, online."}, "fee_basis": "per_class"},
  "publication_streams": ["national_bulletin"], "source": {"state": "Unverified", "notes": "Second wave, proposed third; Chinese script"}
}'::jsonb);
INSERT INTO _profile VALUES ('EG', false, '{
  "calendar": {"timezone": "Africa/Cairo", "weekend": [5, 6], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":         {"start_event": "published", "days": 60, "verified": false},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 12, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "grace":          {"start_event": "registered", "months_after_expiry": 6, "verified": false}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3], "status_map": {}, "human_review_waived": false,
  "filing": {"who_may_file": {"en": "The owner or a licensed agent."}, "foreign_applicant": {"en": "Through a local agent."},
             "nice_edition": "Current edition", "classes_per_application": {"en": "Single-class practice (to confirm)."}, "power_of_attorney": {"en": "Legalised."},
             "status_lookup": {"en": "To confirm."}, "fee_basis": "per_mark"},
  "publication_streams": ["national_bulletin"], "source": {"state": "Unverified", "notes": "Second wave, proposed fourth"}
}'::jsonb);
INSERT INTO _profile VALUES ('JO', false, '{
  "calendar": {"timezone": "Asia/Amman", "weekend": [5, 6], "holidays": []},
  "term": {"years": 10, "from": "filing_date"},
  "timers": {
    "oppose":         {"start_event": "published", "months": 3, "verified": false},
    "renewal_window": {"start_event": "registered", "months_before_expiry": 12, "verified": false},
    "expiry":         {"start_event": "registered", "at_expiry": true, "verified": false},
    "grace":          {"start_event": "registered", "verified": false, "consequence": {"en": "Grace to confirm."}}
  },
  "reminders": {"renewal_window": {"before": "expiry", "months": [6, 3, 1]}},
  "watch_alert_reminders_days": [10, 3], "status_map": {}, "human_review_waived": false,
  "filing": {"who_may_file": {"en": "The owner or a licensed agent."}, "foreign_applicant": {"en": "Through a local agent."},
             "nice_edition": "Current edition", "classes_per_application": {"en": "Single-class practice (to confirm)."}, "power_of_attorney": {"en": "Legalised."},
             "status_lookup": {"en": "To confirm."}, "fee_basis": "per_mark"},
  "publication_streams": ["national_bulletin"], "source": {"state": "Unverified", "notes": "Second wave, proposed fifth; Madrid membership to confirm"}
}'::jsonb);

INSERT INTO registry.registry_profile (registry_id, version, effective_from, verified, rules)
SELECT g.id, 1, DATE '2026-11-12', p.verified, p.rules
  FROM _profile p JOIN registry.registry g ON g.code = p.code;

-- Only a fully verified registry opens (ruled 12 Nov 2026).
UPDATE registry.registry SET supported = true WHERE code = 'AE';

-- -----------------------------------------------------------------------------
-- 3. Publication sources (annex Section 2). active = re-use confirmed and stream to be fetched.
-- -----------------------------------------------------------------------------
INSERT INTO watch.publication_source (registry_id, stream, format, cadence, active, fetch_spec)
SELECT g.id, s.stream::watch.stream, s.format::watch.source_format, s.cadence, s.active, s.spec::jsonb
  FROM (VALUES
    ('AE', 'national_bulletin',   'pdf', 'fortnightly; on demand under the new MoET system (end 2026)', true,
       '{"parser": "moet_bulletin", "fetcher": "page_crawler", "where": "MoET website, Trademark Bulletin (one PDF per publication type per issue)", "mark_as": "image", "reuse": "Permitted, no licence (MoET, 27 Oct 2026)", "state": "Verified"}'),
    ('AE', 'madrid_designations', 'pdf', 'with the national issue', true,
       '{"parser": "moet_madrid_app_publication", "fetcher": "page_crawler", "where": "Same issue, separate PDF (Madrid APP Publication); one designation per page", "objection_days": 30, "reuse": "Permitted", "state": "Verified (sample bulletin 349 read 10 Nov 2026)"}'),
    ('GB', 'national_bulletin',   'xml', 'weekly', false,
       '{"parser": "ukipo_tmj_xml", "fetcher": "page_crawler+xml", "where": "https://www.ipo.gov.uk/t-tmj/", "madrid": "inside the journal", "reuse": "To confirm (Crown copyright / OGL expected)", "state": "Unverified; domain not yet on the allowlist"}'),
    ('EM', 'national_bulletin',   'api', 'every working day', false,
       '{"parser": "euipo_bulletin", "fetcher": "api_client", "where": "EUIPO website; Part A applications, Part B registrations, Part M international registrations", "reuse": "To confirm (EUIPO open-data terms)", "state": "Unverified"}'),
    ('US', 'uspto_tmog',          'pdf', 'weekly, Tuesdays', true,
       '{"parser": "uspto_tmog", "fetcher": "pattern_fetcher", "where": "USPTO website, weekly TMOG; bulk XML available", "madrid": "Section 66(a) applications inside the OG", "reuse": "US government works, free to re-use", "state": "Partly verified (issues held in the USPTO folder)"}'),
    ('SA', 'national_bulletin',   'html', 'to confirm', false, '{"where": "SAIP e-gazette / trademark portal", "state": "Unverified"}'),
    ('OM', 'national_bulletin',   'pdf',  'to confirm', false, '{"where": "Official Gazette, trademark section", "state": "Unverified"}'),
    ('KW', 'national_bulletin',   'pdf',  'to confirm', false, '{"where": "Official Gazette (Kuwait Al-Youm), trademark section", "state": "Unverified"}'),
    ('QA', 'national_bulletin',   'html', 'to confirm', false, '{"where": "Ministry of Commerce and Industry, IP Department", "state": "Unverified"}'),
    ('BH', 'national_bulletin',   'pdf',  'to confirm', false, '{"where": "Official Gazette, trademark section", "state": "Unverified"}'),
    ('TR', 'national_bulletin',   'html', 'twice a month (to confirm)', false, '{"where": "TÜRKPATENT Official Trademark Bulletin (Resmi Marka Bülteni)", "state": "Unverified"}'),
    ('IN', 'national_bulletin',   'pdf',  'weekly, Monday (to confirm)', false, '{"where": "ipindia.gov.in Trade Marks Journal; very large issues", "state": "Unverified"}'),
    ('CN', 'national_bulletin',   'html', 'several issues a month (to confirm)', false, '{"where": "CNIPA Trademark Gazette; Chinese script; access controls to check", "state": "Unverified"}'),
    ('EG', 'national_bulletin',   'pdf',  'monthly (to confirm)', false, '{"where": "Egyptian Trademark Office / ITDA Trademark Gazette", "state": "Unverified"}'),
    ('JO', 'national_bulletin',   'pdf',  'to confirm', false, '{"where": "Official Gazette, trademark section", "state": "Unverified"}'),
    ('WO', 'wipo_gazette',        'api',  'weekly', false, '{"where": "WIPO Gazette of International Marks", "state": "Off until an agreement with WIPO is signed (ruled 12 Nov 2026)"}')
  ) AS s(code, stream, format, cadence, active, spec)
  JOIN registry.registry g ON g.code = s.code;

INSERT INTO watch.publication_schedule (source_id, frequency, weekday, timezone)
SELECT ps.id, 'fortnightly', NULL, 'Asia/Dubai' FROM watch.publication_source ps JOIN registry.registry g ON g.id = ps.registry_id WHERE g.code = 'AE' AND ps.stream = 'national_bulletin';
INSERT INTO watch.publication_schedule (source_id, frequency, weekday, timezone)
SELECT ps.id, 'weekly', 2, 'America/New_York' FROM watch.publication_source ps JOIN registry.registry g ON g.id = ps.registry_id WHERE g.code = 'US';

-- -----------------------------------------------------------------------------
-- 4. Nice class headings, English (Nice Classification class headings; the Arabic headings
--    and the alphabetical lists are loaded from the official MoET/WIPO data files, Step 3.3b —
--    the migration gives the UI a readable English heading meanwhile).
-- -----------------------------------------------------------------------------
UPDATE registry.nice_class c SET heading = c.heading || jsonb_build_object('en', h.en)
FROM (VALUES
  (1, 'Chemicals for use in industry, science and photography, as well as in agriculture, horticulture and forestry; unprocessed artificial resins, unprocessed plastics; fire extinguishing and fire prevention compositions; tempering and soldering preparations; substances for tanning animal skins and hides; adhesives for use in industry; putties and other paste fillers; compost, manures, fertilizers; biological preparations for use in industry and science'),
  (2, 'Paints, varnishes, lacquers; preservatives against rust and against deterioration of wood; colorants, dyes; inks for printing, marking and engraving; raw natural resins; metals in foil and powder form for use in painting, decorating, printing and art'),
  (3, 'Non-medicated cosmetics and toiletry preparations; non-medicated dentifrices; perfumery, essential oils; bleaching preparations and other substances for laundry use; cleaning, polishing, scouring and abrasive preparations'),
  (4, 'Industrial oils and greases, wax; lubricants; dust absorbing, wetting and binding compositions; fuels and illuminants; candles and wicks for lighting'),
  (5, 'Pharmaceuticals, medical and veterinary preparations; sanitary preparations for medical purposes; dietetic food and substances adapted for medical or veterinary use, food for babies; dietary supplements for human beings and animals; plasters, materials for dressings; material for stopping teeth, dental wax; disinfectants; preparations for destroying vermin; fungicides, herbicides'),
  (6, 'Common metals and their alloys, ores; metal materials for building and construction; transportable buildings of metal; non-electric cables and wires of common metal; small items of metal hardware; metal containers for storage or transport; safes'),
  (7, 'Machines, machine tools, power-operated tools; motors and engines, except for land vehicles; machine coupling and transmission components, except for land vehicles; agricultural implements, other than hand-operated hand tools; incubators for eggs; automatic vending machines'),
  (8, 'Hand tools and implements, hand-operated; cutlery; side arms, except firearms; razors'),
  (9, 'Scientific, research, navigation, surveying, photographic, cinematographic, audiovisual, optical, weighing, measuring, signalling, detecting, testing, inspecting, life-saving and teaching apparatus and instruments; apparatus and instruments for conducting, switching, transforming, accumulating, regulating or controlling the distribution or use of electricity; apparatus and instruments for recording, transmitting, reproducing or processing sound, images or data; recorded and downloadable media, computer software, blank digital or analogue recording and storage media; mechanisms for coin-operated apparatus; cash registers, calculating devices; computers and computer peripheral devices; diving suits, divers'' masks, ear plugs for divers, nose clips for divers and swimmers, gloves for divers, breathing apparatus for underwater swimming; fire-extinguishing apparatus'),
  (10, 'Surgical, medical, dental and veterinary apparatus and instruments; artificial limbs, eyes and teeth; orthopaedic articles; suture materials; therapeutic and assistive devices adapted for persons with disabilities; massage apparatus; apparatus, devices and articles for nursing infants; sexual activity apparatus, devices and articles'),
  (11, 'Apparatus and installations for lighting, heating, cooling, steam generating, cooking, drying, ventilating, water supply and sanitary purposes'),
  (12, 'Vehicles; apparatus for locomotion by land, air or water'),
  (13, 'Firearms; ammunition and projectiles; explosives; fireworks'),
  (14, 'Precious metals and their alloys; jewellery, precious and semi-precious stones; horological and chronometric instruments'),
  (15, 'Musical instruments; music stands and stands for musical instruments; conductors'' batons'),
  (16, 'Paper and cardboard; printed matter; bookbinding material; photographs; stationery and office requisites, except furniture; adhesives for stationery or household purposes; drawing materials and materials for artists; paintbrushes; instructional and teaching materials; plastic sheets, films and bags for wrapping and packaging; printers'' type, printing blocks'),
  (17, 'Unprocessed and semi-processed rubber, gutta-percha, gum, asbestos, mica and substitutes for all these materials; plastics and resins in extruded form for use in manufacture; packing, stopping and insulating materials; flexible pipes, tubes and hoses, not of metal'),
  (18, 'Leather and imitations of leather; animal skins and hides; luggage and carrying bags; umbrellas and parasols; walking sticks; whips, harness and saddlery; collars, leashes and clothing for animals'),
  (19, 'Materials, not of metal, for building and construction; rigid pipes, not of metal, for building; asphalt, pitch, tar and bitumen; transportable buildings, not of metal; monuments, not of metal'),
  (20, 'Furniture, mirrors, picture frames; containers, not of metal, for storage or transport; unworked or semi-worked bone, horn, whalebone or mother-of-pearl; shells; meerschaum; yellow amber'),
  (21, 'Household or kitchen utensils and containers; cookware and tableware, except forks, knives and spoons; combs and sponges; brushes, except paintbrushes; brush-making materials; articles for cleaning purposes; unworked or semi-worked glass, except building glass; glassware, porcelain and earthenware'),
  (22, 'Ropes and string; nets; tents and tarpaulins; awnings of textile or synthetic materials; sails; sacks for the transport and storage of materials in bulk; padding, cushioning and stuffing materials, except of paper, cardboard, rubber or plastics; raw fibrous textile materials and substitutes therefor'),
  (23, 'Yarns and threads for textile use'),
  (24, 'Textiles and substitutes for textiles; household linen; curtains of textile or plastic'),
  (25, 'Clothing, footwear, headwear'),
  (26, 'Lace, braid and embroidery, and haberdashery ribbons and bows; buttons, hooks and eyes, pins and needles; artificial flowers; hair decorations; false hair'),
  (27, 'Carpets, rugs, mats and matting, linoleum and other materials for covering existing floors; wall hangings, not of textile'),
  (28, 'Games, toys and playthings; video game apparatus; gymnastic and sporting articles; decorations for Christmas trees'),
  (29, 'Meat, fish, poultry and game; meat extracts; preserved, frozen, dried and cooked fruits and vegetables; jellies, jams, compotes; eggs; milk, cheese, butter, yogurt and other milk products; oils and fats for food'),
  (30, 'Coffee, tea, cocoa and substitutes therefor; rice, pasta and noodles; tapioca and sago; flour and preparations made from cereals; bread, pastries and confectionery; chocolate; ice cream, sorbets and other edible ices; sugar, honey, treacle; yeast, baking-powder; salt, seasonings, spices, preserved herbs; vinegar, sauces and other condiments; ice (frozen water)'),
  (31, 'Raw and unprocessed agricultural, aquacultural, horticultural and forestry products; raw and unprocessed grains and seeds; fresh fruits and vegetables, fresh herbs; natural plants and flowers; bulbs, seedlings and seeds for planting; live animals; foodstuffs and beverages for animals; malt'),
  (32, 'Beers; non-alcoholic beverages; mineral and aerated waters; fruit beverages and fruit juices; syrups and other preparations for making non-alcoholic beverages'),
  (33, 'Alcoholic beverages, except beers; alcoholic preparations for making beverages'),
  (34, 'Tobacco and tobacco substitutes; cigarettes and cigars; electronic cigarettes and oral vaporizers for smokers; smokers'' articles; matches'),
  (35, 'Advertising; business management, organization and administration; office functions'),
  (36, 'Financial, monetary and banking services; insurance services; real estate services'),
  (37, 'Construction services; installation and repair services; mining extraction, oil and gas drilling'),
  (38, 'Telecommunications services'),
  (39, 'Transport; packaging and storage of goods; travel arrangement'),
  (40, 'Treatment of materials; recycling of waste and trash; air purification and treatment of water; printing services; food and drink preservation'),
  (41, 'Education; providing of training; entertainment; sporting and cultural activities'),
  (42, 'Scientific and technological services and research and design relating thereto; industrial analysis, industrial research and industrial design services; quality control and authentication services; design and development of computer hardware and software'),
  (43, 'Services for providing food and drink; temporary accommodation'),
  (44, 'Medical services; veterinary services; hygienic and beauty care for human beings or animals; agriculture, aquaculture, horticulture and forestry services'),
  (45, 'Legal services; security services for the physical protection of tangible property and individuals; dating services, online social networking services; funeral services; babysitting')
) AS h(number, en)
WHERE c.number = h.number;

COMMIT;
