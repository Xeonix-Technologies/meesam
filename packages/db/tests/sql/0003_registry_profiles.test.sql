-- Tests for migration 0003: profiles from the Registry Profiles annex drive timers correctly.
BEGIN;
SET client_min_messages = warning;

DO $$ BEGIN
  ASSERT (SELECT count(*) FROM registry.registry_profile) = 14, 'fourteen profiles (9 launch + 5 second wave)';
  ASSERT (SELECT supported FROM registry.registry WHERE code = 'AE'), 'UAE opens';
  ASSERT (SELECT count(*) FROM registry.registry WHERE supported) = 1, 'only a fully verified registry opens (ruled 12 Nov 2026)';
  ASSERT (SELECT count(*) FROM watch.publication_source WHERE active) = 3, 'AE national, AE Madrid and USPTO streams are fetchable';
  ASSERT (SELECT heading ->> 'en' FROM registry.nice_class WHERE number = 25) = 'Clothing, footwear, headwear';
END $$;

INSERT INTO core.account (id, kind, name, country) VALUES ('00000000-0000-0000-0000-00000000003a', 'owner_company', '{"en": "T"}', 'AE');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000003f1', '00000000-0000-0000-0000-00000000003a', '{"en": "Oro"}', 'word');

-- UAE: verified clocks compute; grace verified per agent material
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
SELECT '00000000-0000-0000-0000-0000000003e1', '00000000-0000-0000-0000-0000000003f1', id, 'AE-1', DATE '2026-02-01', 'new_filing', 'free_new_pending' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000003e1', 'filed', DATE '2026-02-01');
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000003e1', 'opposed', DATE '2026-07-01');
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000003e1', 'registered', DATE '2027-01-10');
DO $$ BEGIN
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e1' AND timer_type = 'priority_document') = DATE '2026-08-01', 'priority document 6 months from filing';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e1' AND timer_type = 'counterstatement') = DATE '2026-07-31', 'counterstatement 30 days from opposition';
  ASSERT (SELECT expiry_date FROM core.record WHERE id = '00000000-0000-0000-0000-0000000003e1') = DATE '2036-02-01', 'AE term 10 years from filing';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e1' AND timer_type = 'grace') = DATE '2036-08-01', 'grace 6 months after expiry';
  ASSERT (SELECT count(*) FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e1' AND awaiting_user_entry) = 0, 'no UAE clock waits for entry';
END $$;

-- US: term from registration; Section 8 window at the 6th anniversary with reminders relative to it; opposition unverified
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
SELECT '00000000-0000-0000-0000-0000000003e2', '00000000-0000-0000-0000-0000000003f1', id, 'US-1', DATE '2025-03-15', 'existing', 'free_loaded' FROM registry.registry WHERE code = 'US';
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000003e2', 'published', DATE '2026-01-06');
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000003e2', 'registered', DATE '2026-04-07');
DO $$ BEGIN
  ASSERT (SELECT awaiting_user_entry FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e2' AND timer_type = 'oppose'), 'US opposition is unverified: user enters it';
  ASSERT (SELECT expiry_date FROM core.record WHERE id = '00000000-0000-0000-0000-0000000003e2') = DATE '2036-04-07', 'US term 10 years from registration';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e2' AND timer_type = 'section8_declaration') = DATE '2032-04-07', 'Section 8 window closes at the 6th anniversary';
  ASSERT (SELECT due_date FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e2' AND timer_type = 'section8_declaration_reminder_12m') = DATE '2031-04-07', 'reminder 12 months before the window closes';
  ASSERT (SELECT due_at FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e2' AND timer_type = 'section8_declaration') = TIMESTAMPTZ '2032-04-07 23:59:00 America/New_York', '23:59 Eastern';
END $$;

-- Jordan: grace has no verified length — a timer that waits, no default
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
SELECT '00000000-0000-0000-0000-0000000003e3', '00000000-0000-0000-0000-0000000003f1', id, 'JO-1', DATE '2026-01-01', 'existing', 'free_loaded' FROM registry.registry WHERE code = 'JO';
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000003e3', 'registered', DATE '2027-01-01');
DO $$ BEGIN
  ASSERT (SELECT awaiting_user_entry FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e3' AND timer_type = 'grace'), 'JO grace waits for entry';
  ASSERT (SELECT awaiting_user_entry FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000003e3' AND timer_type = 'renewal_window'), 'JO renewal window unverified';
END $$;

SELECT 'ALL 0003 TESTS PASSED' AS result;
ROLLBACK;
