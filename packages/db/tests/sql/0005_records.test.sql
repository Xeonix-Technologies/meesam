-- Tests for migration 0005: vault naming, drafts under RLS, historical clocks.
BEGIN;
SET client_min_messages = warning;
DO $$ BEGIN
  ASSERT core.fn_vault_key('8527882', '50003963', DATE '2026-11-03', 'ORC', 'pdf') = '8527882_50003963_031126_ORC.pdf', 'item 43 example';
  ASSERT core.fn_vault_key(NULL, '50003963', DATE '2026-11-03', 'app', 'PDF') = '_50003963_031126_APP.pdf', 'pre-registration document: empty first part';
END $$;

INSERT INTO core.account (id, kind, name, country, verified_at, verification_method) VALUES ('00000000-0000-0000-0000-00000000005a', 'owner_company', '{"en": "D"}', 'AE', now(), 'staff'),
                                                                                           ('00000000-0000-0000-0000-00000000005b', 'owner_company', '{"en": "E"}', 'AE', now(), 'staff');
INSERT INTO core.app_user (id, account_id, email, name, role, status) VALUES ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-00000000005a', 'd@x.test', 'D', 'company_admin', 'active');

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000005a', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000005a1', true);
INSERT INTO core.intake_draft (id, account_id, user_id) VALUES ('00000000-0000-0000-0000-0000000005d1', '00000000-0000-0000-0000-00000000005a', '00000000-0000-0000-0000-0000000005a1');
UPDATE core.intake_draft SET data = data || '{"registry_code": "AE", "stage": "registered"}'::jsonb WHERE id = '00000000-0000-0000-0000-0000000005d1';
DO $$ BEGIN ASSERT (SELECT data ->> 'stage' FROM core.intake_draft WHERE id = '00000000-0000-0000-0000-0000000005d1') = 'registered'; END $$;
-- another account sees no draft
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000005b', true);
DO $$ BEGIN ASSERT (SELECT count(*) FROM core.intake_draft) = 0, 'drafts are private to the account'; END $$;

-- an existing registered mark loaded with its history: the opposition clock is closed as historical (0021)
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-00000000005a', true);
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES ('00000000-0000-0000-0000-0000000005f1', '00000000-0000-0000-0000-00000000005a', '{"en": "Old"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, application_no, filing_date, entry_mode, paid_state)
SELECT '00000000-0000-0000-0000-0000000005e1', '00000000-0000-0000-0000-0000000005f1', id, 'OLD-1', DATE '2020-01-10', 'existing', 'free_loaded' FROM registry.registry WHERE code = 'AE';
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000005e1', 'filed', DATE '2020-01-10');
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000005e1', 'published', DATE '2020-06-01');
INSERT INTO core.record_event (record_id, event_type, event_date) VALUES ('00000000-0000-0000-0000-0000000005e1', 'registered', DATE '2020-09-01');
SELECT core.fn_close_historical_timers('00000000-0000-0000-0000-0000000005e1');
DO $$ BEGIN
  ASSERT (SELECT state FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000005e1' AND timer_type = 'oppose') = 'historical', 'past opposition window closed';
  ASSERT (SELECT state FROM core.timer WHERE record_id = '00000000-0000-0000-0000-0000000005e1' AND timer_type = 'expiry') = 'open', 'expiry stays open (2030)';
  ASSERT (SELECT count(*) FROM core.v_next_dates WHERE record_id = '00000000-0000-0000-0000-0000000005e1' AND timer_type = 'oppose') = 0, 'closed clocks leave next dates';
  ASSERT (SELECT next_timer_type FROM core.v_record_state WHERE record_id = '00000000-0000-0000-0000-0000000005e1') IS NOT NULL;
END $$;
RESET ROLE;
SELECT 'ALL 0005 TESTS PASSED' AS result;
ROLLBACK;
