-- 0036 — Calendar feed per user (System Description 4.11 "Calendar", item 44 xi; plan Step 3 item 6).
-- Each user can switch on a read-only calendar feed of the next dates of the trademarks their account
-- reaches. The feed is opened by a calendar program with no login, so it is addressed by a long secret
-- link; only the hash of that secret is stored. The user can replace the link or switch the feed off.
-- Every date is the registry's own local date (the day ends 23:59 registry time), so it reads the same
-- in any time zone.
BEGIN;

CREATE TABLE core.calendar_feed (
  user_id    uuid PRIMARY KEY REFERENCES core.app_user(id),
  token_hash bytea NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_read_at timestamptz NULL
);
ALTER TABLE core.calendar_feed ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON core.calendar_feed FROM meesam_app;

-- the signed-in user switches the feed on or replaces its link (the web service makes the secret and passes its hash)
CREATE FUNCTION core.fn_calendar_feed_set(p_token_hash bytea) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); u core.app_user;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me.id;
  IF u.id IS NULL OR u.status <> 'active' OR octet_length(p_token_hash) <> 32 THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  INSERT INTO core.calendar_feed (user_id, token_hash) VALUES (u.id, p_token_hash)
  ON CONFLICT (user_id) DO UPDATE SET token_hash = EXCLUDED.token_hash, created_at = now(), last_read_at = NULL;
END $$;

CREATE FUNCTION core.fn_calendar_feed_off() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  DELETE FROM core.calendar_feed WHERE user_id = platform.current_user_id()
$$;

CREATE FUNCTION core.fn_calendar_feed_status(OUT created_at timestamptz, OUT last_read_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT f.created_at, f.last_read_at FROM core.calendar_feed f WHERE f.user_id = platform.current_user_id()
$$;

-- The feed itself, by the hash of the secret in its link. No session: the secret is the key.
-- The open statutory dates of every live trademark the user's account reaches; nothing for a user who is
-- no longer active or whose account is not verified.
CREATE FUNCTION core.fn_calendar_events(p_token_hash bytea)
RETURNS TABLE (locale text, account_id uuid, timer_id uuid, record_id uuid, timer_type text, due_date date, timezone text,
               mark_text jsonb, number text, registry_code text, updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE u core.app_user;
BEGIN
  SELECT au.* INTO u FROM core.calendar_feed f JOIN core.app_user au ON au.id = f.user_id JOIN core.account a ON a.id = au.account_id
   WHERE f.token_hash = p_token_hash AND au.status = 'active' AND au.role <> 'viewer' AND a.verified_at IS NOT NULL;
  IF u.id IS NULL THEN RETURN; END IF;
  UPDATE core.calendar_feed f SET last_read_at = now() WHERE f.user_id = u.id;
  -- a first row with no date carries the reader's language even when there is nothing to show
  RETURN QUERY SELECT u.locale, u.account_id, NULL::uuid, NULL::uuid, NULL::text, NULL::date, NULL::text, NULL::jsonb, NULL::text, NULL::text, NULL::timestamptz;
  RETURN QUERY
    SELECT u.locale, u.account_id, t.id, t.record_id, t.timer_type, t.due_date, COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC'),
           r.mark_text, COALESCE(r.registration_no, r.application_no), g.code::text, t.updated_at
      FROM core.timer t
      JOIN core.record r ON r.id = t.record_id AND NOT r.terminal
      JOIN registry.registry g ON g.id = r.registry_id
      LEFT JOIN registry.registry_profile p ON p.registry_id = r.registry_id
     WHERE t.state = 'open' AND t.due_date IS NOT NULL AND t.family = 'statutory'
       AND core.fn_can_access(t.record_id, u.account_id)
     ORDER BY t.due_date;
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_calendar_feed_set(bytea), core.fn_calendar_feed_off(), core.fn_calendar_feed_status(), core.fn_calendar_events(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_calendar_feed_set(bytea), core.fn_calendar_feed_off(), core.fn_calendar_feed_status(), core.fn_calendar_events(bytea) TO meesam_app;

COMMIT;
