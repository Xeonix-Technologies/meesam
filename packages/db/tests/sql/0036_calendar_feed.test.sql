-- Tests for migration 0036: the calendar feed shows the user's own account's dates, by secret link only.
BEGIN;
SET client_min_messages = warning;
INSERT INTO core.account (id, kind, name, country, verified_at, verification_method, verification_status) VALUES
  ('00000000-0000-0000-0000-0000000036a0', 'owner_company', '{"en": "Owner"}', 'AE', now(), 'staff', 'verified'),
  ('00000000-0000-0000-0000-0000000036a9', 'owner_company', '{"en": "Other"}', 'AE', now(), 'staff', 'verified');
INSERT INTO core.app_user (id, account_id, email, name, role, status, locale) VALUES
  ('00000000-0000-0000-0000-0000000036c0', '00000000-0000-0000-0000-0000000036a0', 'adm@x36.test', 'Adm', 'company_admin', 'active', 'ar'),
  ('00000000-0000-0000-0000-0000000036c9', '00000000-0000-0000-0000-0000000036a9', 'oth@x36.test', 'Oth', 'company_admin', 'active', 'en');
INSERT INTO core.mark_family (id, owner_account_id, name, mark_type) VALUES
  ('00000000-0000-0000-0000-0000000036f1', '00000000-0000-0000-0000-0000000036a0', '{"en": "mine"}', 'word'),
  ('00000000-0000-0000-0000-0000000036f9', '00000000-0000-0000-0000-0000000036a9', '{"en": "theirs"}', 'word');
INSERT INTO core.record (id, mark_family_id, registry_id, entry_mode, paid_state, mark_text)
  SELECT x.id, x.fam, g.id, 'existing', 'free_loaded', x.txt FROM registry.registry g,
    (VALUES ('00000000-0000-0000-0000-0000000036e1'::uuid, '00000000-0000-0000-0000-0000000036f1'::uuid, '{"en": "mine"}'::jsonb),
            ('00000000-0000-0000-0000-0000000036e9'::uuid, '00000000-0000-0000-0000-0000000036f9'::uuid, '{"en": "theirs"}'::jsonb)) x(id, fam, txt) WHERE g.code = 'AE';
DELETE FROM core.timer WHERE record_id IN ('00000000-0000-0000-0000-0000000036e1', '00000000-0000-0000-0000-0000000036e9');
INSERT INTO core.timer (record_id, family, timer_type, due_date, source, state) VALUES
  ('00000000-0000-0000-0000-0000000036e1', 'statutory', 'expiry', DATE '2030-05-01', 'profile', 'open'),
  ('00000000-0000-0000-0000-0000000036e1', 'statutory', 'oppose', DATE '2027-01-20', 'profile', 'met'),
  ('00000000-0000-0000-0000-0000000036e1', 'reminder', 'renewal_window_reminder_6m', DATE '2029-11-01', 'profile', 'open'),
  ('00000000-0000-0000-0000-0000000036e9', 'statutory', 'expiry', DATE '2031-01-01', 'profile', 'open');

SET LOCAL ROLE meesam_app;
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000036a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000036c0', true);
DO $$
DECLARE denied boolean := false;
BEGIN
  ASSERT (SELECT created_at IS NULL FROM core.fn_calendar_feed_status()), 'off to begin with';
  PERFORM core.fn_calendar_feed_set(sha256('secret-one'::bytea));
  ASSERT (SELECT created_at IS NOT NULL FROM core.fn_calendar_feed_status()), 'switched on';
  BEGIN PERFORM 1 FROM core.calendar_feed; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the app role cannot read the feed table';
END $$;
-- the feed is read with no session at all
SELECT set_config('meesam.account_id', '', true);
SELECT set_config('meesam.user_id', '', true);
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.fn_calendar_events(sha256('wrong'::bytea))) = 0, 'a wrong secret gives nothing';
  ASSERT (SELECT count(*) FROM core.fn_calendar_events(sha256('secret-one'::bytea)) WHERE timer_id IS NOT NULL) = 1, 'only the open statutory date of the user''s own trademark';
  ASSERT (SELECT timer_type = 'expiry' AND due_date = DATE '2030-05-01' AND timezone = 'Asia/Dubai' AND locale = 'ar' AND mark_text ->> 'en' = 'mine'
            FROM core.fn_calendar_events(sha256('secret-one'::bytea)) WHERE timer_id IS NOT NULL), 'with the registry''s time zone and the reader''s language';
END $$;
-- replacing the link ends the old one; switching off ends the feed
SELECT set_config('meesam.account_id', '00000000-0000-0000-0000-0000000036a0', true);
SELECT set_config('meesam.user_id', '00000000-0000-0000-0000-0000000036c0', true);
SELECT core.fn_calendar_feed_set(sha256('secret-two'::bytea));
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM core.fn_calendar_events(sha256('secret-one'::bytea))) = 0, 'the old link stops working';
  ASSERT (SELECT count(*) FROM core.fn_calendar_events(sha256('secret-two'::bytea)) WHERE timer_id IS NOT NULL) = 1, 'the new link works';
  PERFORM core.fn_calendar_feed_off();
  ASSERT (SELECT count(*) FROM core.fn_calendar_events(sha256('secret-two'::bytea))) = 0, 'switched off';
END $$;
RESET ROLE;
SELECT 'ALL 0036 TESTS PASSED' AS result;
ROLLBACK;
