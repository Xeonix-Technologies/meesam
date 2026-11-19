-- 0039 — Acknowledge, assign, escalate (System Description 4.11; plan Step 3 item 6, third part).
-- "On every hard-deadline notification any user may acknowledge it or assign it to a user; both are audited
--  and shown on the record. A Critical notification still unacknowledged at 7 days remaining is re-sent to the
--  Administrator marked 'unacknowledged', and at 3 days to every user of the account."
-- Acknowledgement and assignment are kept per account: each account that reaches a trademark looks after its
-- own side. The app role only reads its own account's rows; changes go through the functions below.
-- (Watch notifications get the same treatment when the watch is built.)
BEGIN;

CREATE TABLE core.timer_ack (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  timer_id                uuid NOT NULL REFERENCES core.timer(id),
  record_id               uuid NOT NULL REFERENCES core.record(id),
  account_id              uuid NOT NULL REFERENCES core.account(id),
  acknowledged_at         timestamptz NULL,
  acknowledged_by_user_id uuid NULL REFERENCES core.app_user(id),
  assigned_user_id        uuid NULL REFERENCES core.app_user(id),
  assigned_at             timestamptz NULL,
  assigned_by_user_id     uuid NULL REFERENCES core.app_user(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (timer_id, account_id)
);
CREATE INDEX ON core.timer_ack (record_id);
ALTER TABLE core.timer_ack ENABLE ROW LEVEL SECURITY;
CREATE POLICY timer_ack_select ON core.timer_ack FOR SELECT TO meesam_app USING (account_id = platform.current_account_id());
GRANT SELECT ON core.timer_ack TO meesam_app;
-- audited like every other change to a record, and shown on its timeline (rule 3)
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON core.timer_ack FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row();

-- who may act: an active user (not a Viewer) of a verified account that reaches the record of this open deadline
CREATE FUNCTION core.fn_timer_ack_actor(p_timer_id uuid, OUT account_id uuid, OUT user_id uuid, OUT record_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); u core.app_user; t core.timer;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND app_user.account_id = me.id;
  IF u.id IS NULL OR u.status <> 'active' OR u.role = 'viewer' THEN RAISE EXCEPTION 'not allowed for this user' USING ERRCODE = '42501'; END IF;
  SELECT * INTO t FROM core.timer WHERE id = p_timer_id;
  IF t.id IS NULL OR t.state <> 'open' OR NOT core.fn_can_access(t.record_id, me.id) THEN RAISE EXCEPTION 'no such open deadline' USING ERRCODE = '22023'; END IF;
  account_id := me.id; user_id := u.id; record_id := t.record_id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_timer_ack_actor(uuid) FROM PUBLIC, meesam_app;

CREATE FUNCTION core.fn_timer_acknowledge(p_timer_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM core.fn_timer_ack_actor(p_timer_id);
  INSERT INTO core.timer_ack (timer_id, record_id, account_id, acknowledged_at, acknowledged_by_user_id)
  VALUES (p_timer_id, a.record_id, a.account_id, now(), a.user_id)
  ON CONFLICT (timer_id, account_id) DO UPDATE SET acknowledged_at = now(), acknowledged_by_user_id = EXCLUDED.acknowledged_by_user_id, updated_at = now()
   WHERE core.timer_ack.acknowledged_at IS NULL;
END $$;

-- assigns the deadline to a user of the caller's own account, or to nobody (NULL)
CREATE FUNCTION core.fn_timer_assign(p_timer_id uuid, p_user_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM core.fn_timer_ack_actor(p_timer_id);
  IF p_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.app_user u WHERE u.id = p_user_id AND u.account_id = a.account_id AND u.status = 'active' AND u.role <> 'viewer') THEN
    RAISE EXCEPTION 'the user is not an active user of this account' USING ERRCODE = '22023';
  END IF;
  INSERT INTO core.timer_ack (timer_id, record_id, account_id, assigned_user_id, assigned_at, assigned_by_user_id)
  VALUES (p_timer_id, a.record_id, a.account_id, p_user_id, CASE WHEN p_user_id IS NOT NULL THEN now() END, a.user_id)
  ON CONFLICT (timer_id, account_id) DO UPDATE SET assigned_user_id = EXCLUDED.assigned_user_id, assigned_at = EXCLUDED.assigned_at,
         assigned_by_user_id = EXCLUDED.assigned_by_user_id, updated_at = now();
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_timer_acknowledge(uuid), core.fn_timer_assign(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_timer_acknowledge(uuid), core.fn_timer_assign(uuid, uuid) TO meesam_app;

-- Escalation: an open hard deadline that an account has not acknowledged is re-sent, marked unacknowledged,
-- to that account's Administrator at 7 days remaining and to every user of the account at 3 days.
-- Where an ordinary reminder for the same deadline is still waiting to be sent to the same user, that
-- reminder is marked instead, so the user gets one e-mail, not two. Returns the e-mails written or marked.
CREATE FUNCTION core.fn_reminders_escalate(p_now timestamptz DEFAULT now()) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE x record; n integer := 0; k integer;
BEGIN
  FOR x IN
    SELECT t.id AS timer_id, t.record_id, t.timer_type, t.due_date, v.tz, t.due_date - v.today AS days,
           CASE WHEN t.due_date - v.today <= 3 THEN 'esc3' ELSE 'esc7' END AS point, a.account_id
      FROM core.timer t
      JOIN core.record r ON r.id = t.record_id AND NOT r.terminal
      LEFT JOIN registry.registry_profile p ON p.registry_id = r.registry_id
      CROSS JOIN LATERAL (SELECT COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC') AS tz,
                                 (p_now AT TIME ZONE COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC'))::date AS today) v
      JOIN (SELECT DISTINCT record_id, account_id FROM core.v_record_access) a ON a.record_id = t.record_id
     WHERE t.state = 'open' AND t.family = 'statutory' AND t.due_date IS NOT NULL AND NOT t.awaiting_user_entry
       AND t.timer_type <> 'renewal_window'                         -- a window opening is not a deadline
       AND t.due_date - v.today BETWEEN 0 AND 7
       AND NOT EXISTS (SELECT 1 FROM core.timer_ack k WHERE k.timer_id = t.id AND k.account_id = a.account_id AND k.acknowledged_at IS NOT NULL)
  LOOP
    -- once per deadline, account and step
    CONTINUE WHEN EXISTS (SELECT 1 FROM platform.notification q WHERE q.dedupe_key = format('esc:%s:%s:a:%s', x.timer_id, x.point, x.account_id));
    INSERT INTO platform.notification (account_id, channel, kind, record_id, severity, timer_id, point, dedupe_key, payload)
    VALUES (x.account_id, 'in_app', 'timer_unacknowledged', x.record_id, 'critical', x.timer_id, x.point,
            format('esc:%s:%s:a:%s', x.timer_id, x.point, x.account_id),
            jsonb_build_object('timer_type', x.timer_type, 'due_date', x.due_date, 'days', x.days, 'timezone', x.tz, 'unack', true));

    -- an ordinary reminder still waiting for the same user and deadline carries the mark
    UPDATE platform.notification q SET payload = q.payload || '{"unack": true}'::jsonb
      FROM core.app_user u
     WHERE q.timer_id = x.timer_id AND q.channel = 'email' AND q.status = 'queued' AND q.kind = 'timer_due' AND q.user_id = u.id
       AND u.account_id = x.account_id AND u.status = 'active'
       AND NOT COALESCE((q.payload ->> 'unack')::boolean, false)
       AND (x.point = 'esc3' OR u.role IN ('company_admin', 'agency_admin'));
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

    INSERT INTO platform.notification (account_id, user_id, channel, kind, record_id, severity, timer_id, point, dedupe_key, payload)
    SELECT u.account_id, u.id, 'email', 'timer_due', x.record_id, 'critical', x.timer_id, x.point,
           format('esc:%s:%s:u:%s', x.timer_id, x.point, u.id),
           jsonb_build_object('timer_type', x.timer_type, 'due_date', x.due_date, 'days', x.days, 'timezone', x.tz, 'unack', true)
      FROM core.app_user u
     WHERE u.account_id = x.account_id AND u.status = 'active' AND u.role <> 'viewer'
       AND (x.point = 'esc3' OR u.role IN ('company_admin', 'agency_admin'))
       AND NOT EXISTS (SELECT 1 FROM platform.notification q WHERE q.timer_id = x.timer_id AND q.user_id = u.id AND q.channel = 'email'
                          AND q.status = 'queued' AND q.kind = 'timer_due')
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_reminders_escalate(timestamptz) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION core.fn_reminders_escalate(timestamptz) TO meesam_worker, meesam_admin;

-- the hand-over to the worker now says whether a reminder is marked unacknowledged
DROP FUNCTION platform.fn_reminder_mails_take(integer);
CREATE FUNCTION platform.fn_reminder_mails_take(p_limit integer DEFAULT 25)
RETURNS TABLE (id uuid, email citext, name text, locale text, account_id uuid, record_id uuid, severity text, point text,
               timer_type text, due_date date, days integer, timezone text, mark_text jsonb, number text, registry_code text, unack boolean)
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
         r.mark_text, COALESCE(r.registration_no, r.application_no), g.code::text, COALESCE((t.payload ->> 'unack')::boolean, false)
    FROM taken t JOIN core.app_user u ON u.id = t.user_id AND u.status = 'active'
    JOIN core.record r ON r.id = t.record_id JOIN registry.registry g ON g.id = r.registry_id
$$;
REVOKE EXECUTE ON FUNCTION platform.fn_reminder_mails_take(integer) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_reminder_mails_take(integer) TO meesam_worker, meesam_admin;

COMMIT;
