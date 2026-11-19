-- 0037 — Notification preferences and the daily summary (System Description 4.11; plan Step 3 item 6, second part).
-- Section 4.11 channel rules:
--   Critical  — in-app and e-mail, immediately, every time; cannot be switched off.
--   Important — in-app and e-mail, immediately; daily digest optional.
--   Routine   — in-app; daily digest by e-mail (an edit by the other side, a stage recorded).
-- Each user sets whether Important reminders come at once or in the daily summary, and whether the daily
-- summary of Routine changes is sent. Critical is not a preference. Language is the user's own (Your details).
BEGIN;

CREATE TABLE core.user_notify_pref (
  user_id          uuid PRIMARY KEY REFERENCES core.app_user(id),
  important_digest boolean NOT NULL DEFAULT false,   -- Important reminders in the daily summary instead of at once
  routine_digest   boolean NOT NULL DEFAULT true,    -- daily summary of changes made by the other side
  last_digest_at   timestamptz NULL,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE core.user_notify_pref ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON core.user_notify_pref FROM meesam_app;

CREATE FUNCTION core.fn_notify_pref(OUT important_digest boolean, OUT routine_digest boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT COALESCE(p.important_digest, false), COALESCE(p.routine_digest, true)
    FROM (SELECT platform.current_user_id() AS id) me LEFT JOIN core.user_notify_pref p ON p.user_id = me.id
$$;

CREATE FUNCTION core.fn_notify_pref_set(p_important_digest boolean, p_routine_digest boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE u core.app_user;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = platform.current_account_id();
  IF u.id IS NULL OR u.status <> 'active' THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  INSERT INTO core.user_notify_pref (user_id, important_digest, routine_digest)
  VALUES (u.id, COALESCE(p_important_digest, false), COALESCE(p_routine_digest, true))
  ON CONFLICT (user_id) DO UPDATE SET important_digest = EXCLUDED.important_digest, routine_digest = EXCLUDED.routine_digest, updated_at = now();
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_notify_pref(), core.fn_notify_pref_set(boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_notify_pref(), core.fn_notify_pref_set(boolean, boolean) TO meesam_app;

-- Immediate reminder e-mails: everything Critical, and Important for users who did not choose the daily summary.
CREATE OR REPLACE FUNCTION platform.fn_reminder_mails_take(p_limit integer DEFAULT 25)
RETURNS TABLE (id uuid, email citext, name text, locale text, account_id uuid, record_id uuid, severity text, point text,
               timer_type text, due_date date, days integer, timezone text, mark_text jsonb, number text, registry_code text)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, registry, public, pg_temp AS $$
  WITH picked AS (
    SELECT n.id FROM platform.notification n
     WHERE n.channel = 'email' AND n.status = 'queued' AND n.kind = 'timer_due' AND n.user_id IS NOT NULL
       AND (n.severity = 'critical' OR NOT COALESCE((SELECT p.important_digest FROM core.user_notify_pref p WHERE p.user_id = n.user_id), false))
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

-- The daily summary. Returns, for every user whose summary is due and who has something in it, one row per item:
--   'reminder' — an Important reminder held for the summary (the user chose that);
--   'changes'  — a trademark the other side changed since the user's last summary, with the number of changes.
-- A summary is due once per day, after p_hour_utc. Taking it marks it sent: the held reminders are logged as
-- sent and the user's last summary time moves on, so a second call the same day returns nothing.
CREATE FUNCTION platform.fn_digest_take(p_now timestamptz DEFAULT now(), p_hour_utc integer DEFAULT 4)
RETURNS TABLE (user_id uuid, email citext, name text, locale text, account_id uuid, item text, record_id uuid,
               mark_text jsonb, number text, registry_code text, timer_type text, due_date date, days integer, changes integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, registry, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_cut timestamptz := date_trunc('day', p_now AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + make_interval(hours => p_hour_utc);
BEGIN
  IF p_now < v_cut THEN RETURN; END IF;   -- today's summary time has not come yet
  CREATE TEMP TABLE IF NOT EXISTS _digest_due (user_id uuid PRIMARY KEY, since timestamptz) ON COMMIT DROP;
  TRUNCATE _digest_due;
  INSERT INTO _digest_due
  SELECT u.id, COALESCE(p.last_digest_at, p_now - interval '1 day')
    FROM core.app_user u JOIN core.account a ON a.id = u.account_id AND a.verified_at IS NOT NULL AND NOT a.is_staff
    LEFT JOIN core.user_notify_pref p ON p.user_id = u.id
   WHERE u.status = 'active' AND u.role <> 'viewer' AND (p.last_digest_at IS NULL OR p.last_digest_at < v_cut);

  RETURN QUERY
  WITH held AS (
    UPDATE platform.notification n SET status = 'sent', sent_at = p_now
      FROM _digest_due d JOIN core.user_notify_pref p ON p.user_id = d.user_id AND p.important_digest
     WHERE n.user_id = d.user_id AND n.channel = 'email' AND n.status = 'queued' AND n.kind = 'timer_due' AND n.severity = 'important'
    RETURNING n.user_id AS uid, n.record_id AS rid, n.payload
  ), changed AS (
    SELECT d.user_id AS uid, n.record_id AS rid, count(*)::integer AS c
      FROM _digest_due d JOIN core.app_user u ON u.id = d.user_id
      LEFT JOIN core.user_notify_pref p ON p.user_id = d.user_id
      JOIN platform.notification n ON n.account_id = u.account_id AND n.channel = 'in_app' AND n.kind = 'record_edited'
                                   AND n.record_id IS NOT NULL AND n.created_at > d.since AND n.created_at <= p_now
     WHERE COALESCE(p.routine_digest, true) AND core.fn_can_access(n.record_id, u.account_id)
     GROUP BY d.user_id, n.record_id
  ), items AS (
    SELECT h.uid, 'reminder'::text AS item, h.rid, h.payload ->> 'timer_type' AS tt, (h.payload ->> 'due_date')::date AS dd, (h.payload ->> 'days')::integer AS dy, NULL::integer AS c FROM held h
    UNION ALL
    SELECT c.uid, 'changes', c.rid, NULL, NULL, NULL, c.c FROM changed c
  )
  SELECT u.id, u.email, u.name, u.locale, u.account_id, i.item, i.rid, r.mark_text, COALESCE(r.registration_no, r.application_no), g.code::text, i.tt, i.dd, i.dy, i.c
    FROM items i JOIN core.app_user u ON u.id = i.uid
    JOIN core.record r ON r.id = i.rid JOIN registry.registry g ON g.id = r.registry_id
   ORDER BY u.id, i.item DESC, i.dd NULLS LAST;

  -- every user whose summary was due has now had today's, with or without content
  INSERT INTO core.user_notify_pref (user_id, last_digest_at) SELECT d.user_id, p_now FROM _digest_due d
  ON CONFLICT (user_id) DO UPDATE SET last_digest_at = EXCLUDED.last_digest_at;
END $$;
REVOKE EXECUTE ON FUNCTION platform.fn_digest_take(timestamptz, integer) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_digest_take(timestamptz, integer) TO meesam_worker, meesam_admin;

COMMIT;
