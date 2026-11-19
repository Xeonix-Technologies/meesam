-- 0035 — Deadline reminders (System Description 4.11, item 44; plan Step 3 item 6, first part).
-- The timer engine: for every open clock on a live record it works out the reminder points of Section 4.11,
-- and when a point falls due (by the registry's own calendar day) writes one notification per account
-- (in-app) and one per user (e-mail). The worker runs it every hour and sends the e-mails. Both steps are
-- idempotent: a point is notified once, whatever the number of runs.
-- Cadences are data (platform.reminder_cadence), not literals in code; the renewal months stay in each
-- registry profile, which already produces a reminder clock for each of them.
BEGIN;

ALTER TABLE platform.notification ADD COLUMN severity text NULL CHECK (severity IN ('critical', 'important', 'routine', 'info'));
ALTER TABLE platform.notification ADD COLUMN timer_id uuid NULL REFERENCES core.timer(id);
ALTER TABLE platform.notification ADD COLUMN point text NULL;
ALTER TABLE platform.notification ADD COLUMN last_error text NULL;
CREATE INDEX notification_email_queue ON platform.notification (created_at) WHERE channel = 'email' AND status = 'queued';

-- When a clock reminds (Section 4.11 "Cadences"). '*' is the rule for any hard deadline not listed.
CREATE TABLE platform.reminder_cadence (
  timer_type    text PRIMARY KEY,
  at_start      boolean NOT NULL DEFAULT false,      -- when the clock starts
  months_before integer[] NOT NULL DEFAULT '{}',
  days_before   integer[] NOT NULL DEFAULT '{}',
  on_due        boolean NOT NULL DEFAULT true,       -- on the due day
  note          text NULL
);
INSERT INTO platform.reminder_cadence (timer_type, at_start, months_before, days_before, on_due, note) VALUES
  ('oppose',            true,  '{}',    '{10,3}',    true, '30-day clock: at start, at 10 days, at 3 days, on the due day'),
  ('counterstatement',  true,  '{}',    '{10,3}',    true, '30-day clock'),
  ('appeal',            true,  '{}',    '{10,3}',    true, '30-day clock'),
  ('pay_registration',  true,  '{}',    '{10,3}',    true, '30-day clock; the monthly reminder while the penalty accrues is not built yet'),
  ('priority_document', false, '{1}',   '{10,3}',    true, 'hard deadline, 6 months: 1 month, 10 days, 3 days, due day (cadence Inferred)'),
  ('renewal_window',    false, '{}',    '{}',        true, 'window open'),
  ('expiry',            false, '{}',    '{}',        true, 'expiry day; the 6, 3 and 1 month reminders are reminder clocks from the registry profile'),
  ('grace',             false, '{3,1}', '{}',        true, '3 months and 1 month before the grace period ends, and on the day'),
  ('*',                 false, '{3,1}', '{10,3}',    true, 'any other hard deadline (cadence Inferred)');
GRANT SELECT ON platform.reminder_cadence TO meesam_worker, meesam_staff, meesam_admin, meesam_readonly;

-- Works out the points that fell due and writes their notifications. Returns how many notifications it wrote.
-- A point is taken when its day (registry-local) is today or within the three days before (so a short
-- outage loses nothing), and never from before the clock existed (no reminders about the past when a mark is loaded).
CREATE FUNCTION core.fn_reminders_materialise(p_now timestamptz DEFAULT now()) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE x record; n integer := 0; k integer; v_sev text; v_days integer; v_deadline date;
BEGIN
  FOR x IN
    WITH live AS (
      SELECT t.id AS timer_id, t.record_id, t.family, t.timer_type, t.due_date,
             COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC') AS tz, t.created_at
        FROM core.timer t
        JOIN core.record r ON r.id = t.record_id AND NOT r.terminal
        LEFT JOIN registry.registry_profile p ON p.registry_id = r.registry_id
       WHERE t.state = 'open' AND t.due_date IS NOT NULL AND NOT t.awaiting_user_entry AND t.family IN ('statutory', 'reminder')
    ), cal AS (
      SELECT l.*, (p_now AT TIME ZONE l.tz)::date AS today, (l.created_at AT TIME ZONE l.tz)::date AS born,
             COALESCE(c.at_start, d.at_start) AS at_start, COALESCE(c.months_before, d.months_before) AS months_before,
             COALESCE(c.days_before, d.days_before) AS days_before, COALESCE(c.on_due, d.on_due) AS on_due
        FROM live l
        LEFT JOIN platform.reminder_cadence c ON c.timer_type = l.timer_type
        JOIN platform.reminder_cadence d ON d.timer_type = '*'
    ), points AS (
      -- a reminder clock from the registry profile is itself the point
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'on'::text AS point, due_date AS point_date FROM cal WHERE family = 'reminder'
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'start', born FROM cal WHERE family = 'statutory' AND at_start AND due_date >= today
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'm' || m, (due_date - make_interval(months => m))::date
        FROM cal, unnest(months_before) m WHERE family = 'statutory'
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'd' || d, due_date - d FROM cal, unnest(days_before) d WHERE family = 'statutory'
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'due', due_date FROM cal WHERE family = 'statutory' AND on_due
    )
    -- the latest point that fell due for each clock
    SELECT DISTINCT ON (timer_id) * FROM points
     WHERE point_date <= today AND point_date >= today - 3 AND point_date >= born
     ORDER BY timer_id, point_date DESC, (point = 'start')
  LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM platform.notification q WHERE q.timer_id = x.timer_id AND q.point = x.point);
    -- days to the hard deadline this point is about: the clock itself, or for a renewal reminder the expiry it counts down to
    v_deadline := CASE WHEN x.timer_type LIKE '%\_reminder\_%m'
                       THEN COALESCE((SELECT min(t2.due_date) FROM core.timer t2 WHERE t2.record_id = x.record_id AND t2.timer_type = 'expiry' AND t2.state = 'open'), x.due_date)
                       ELSE x.due_date END;
    v_days := v_deadline - x.today;
    -- Section 4.11: Critical = a hard deadline inside 30 days (a calendar month is read as inside); a window opening = Important
    v_sev := CASE WHEN x.timer_type = 'renewal_window' THEN 'important' WHEN v_days <= 31 THEN 'critical' ELSE 'important' END;

    INSERT INTO platform.notification (account_id, channel, kind, record_id, severity, timer_id, point, dedupe_key, payload)
    SELECT a.account_id, 'in_app', 'timer_due', x.record_id, v_sev, x.timer_id, x.point,
           format('rem:%s:%s:a:%s', x.timer_id, x.point, a.account_id),
           jsonb_build_object('timer_type', x.timer_type, 'due_date', v_deadline, 'days', v_days, 'timezone', x.tz)
      FROM (SELECT DISTINCT account_id FROM core.v_record_access WHERE record_id = x.record_id) a
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

    -- recipients (4.11): the Administrator and, while records are not assigned to users, every Agent and
    -- Trademark manager of each account that reaches the record; a Viewer receives nothing
    INSERT INTO platform.notification (account_id, user_id, channel, kind, record_id, severity, timer_id, point, dedupe_key, payload)
    SELECT u.account_id, u.id, 'email', 'timer_due', x.record_id, v_sev, x.timer_id, x.point,
           format('rem:%s:%s:u:%s', x.timer_id, x.point, u.id),
           jsonb_build_object('timer_type', x.timer_type, 'due_date', v_deadline, 'days', v_days, 'timezone', x.tz)
      FROM (SELECT DISTINCT account_id FROM core.v_record_access WHERE record_id = x.record_id) a
      JOIN core.app_user u ON u.account_id = a.account_id AND u.status = 'active' AND u.role <> 'viewer'
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  END LOOP;
  RETURN n;
END $$;

-- Hands queued reminder e-mails to the worker and marks them sent; a failed send is reported back below.
CREATE FUNCTION platform.fn_reminder_mails_take(p_limit integer DEFAULT 25)
RETURNS TABLE (id uuid, email citext, name text, locale text, account_id uuid, record_id uuid, severity text, point text,
               timer_type text, due_date date, days integer, timezone text, mark_text jsonb, number text, registry_code text)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, registry, public, pg_temp AS $$
  WITH picked AS (
    SELECT n.id FROM platform.notification n
     WHERE n.channel = 'email' AND n.status = 'queued' AND n.kind = 'timer_due' AND n.user_id IS NOT NULL
     ORDER BY n.created_at LIMIT GREATEST(p_limit, 1) FOR UPDATE SKIP LOCKED
  ), taken AS (
    UPDATE platform.notification n SET status = 'sent', sent_at = now() FROM picked WHERE n.id = picked.id
    RETURNING n.id, n.user_id, n.account_id, n.record_id, n.severity, n.point, n.payload)
  SELECT t.id, u.email, u.name, u.locale, t.account_id, t.record_id, t.severity, t.point,
         t.payload ->> 'timer_type', (t.payload ->> 'due_date')::date, (t.payload ->> 'days')::integer, t.payload ->> 'timezone',
         r.mark_text, COALESCE(r.registration_no, r.application_no), g.code::text
    FROM taken t JOIN core.app_user u ON u.id = t.user_id AND u.status = 'active'
    JOIN core.record r ON r.id = t.record_id JOIN registry.registry g ON g.id = r.registry_id
$$;

CREATE FUNCTION platform.fn_notification_failed(p_id uuid, p_error text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
  UPDATE platform.notification SET status = 'failed', sent_at = NULL, last_error = left(p_error, 500) WHERE id = p_id
$$;

REVOKE EXECUTE ON FUNCTION core.fn_reminders_materialise(timestamptz), platform.fn_reminder_mails_take(integer), platform.fn_notification_failed(uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION core.fn_reminders_materialise(timestamptz), platform.fn_reminder_mails_take(integer), platform.fn_notification_failed(uuid, text) TO meesam_worker, meesam_admin;

COMMIT;
