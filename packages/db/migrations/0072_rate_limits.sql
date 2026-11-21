-- 0072 — Limits on the sign-in pages (plan item A7, sign-in limits review, 21 Nov 2026).
-- Found in the review: failed sign-ins were limited per e-mail address only (8 in 15 minutes); one network address
-- could try many addresses, and the "forgot password", "send the link again" and "create account" forms had no
-- limit, so they could be used to flood a person's inbox or to create accounts in bulk.
-- A small counter of events per key and time window closes these; the forms keep answering in the same words
-- whether or not a limit was reached, so nothing about an address is revealed.
BEGIN;

CREATE TABLE platform.rate_event (
  key        text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON platform.rate_event (key, created_at DESC);
REVOKE ALL ON platform.rate_event FROM meesam_app;

-- Counts one event for the key and says whether it is within the limit (true = allowed).
CREATE FUNCTION platform.fn_rate_hit(p_key text, p_max integer, p_window interval) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  IF p_key IS NULL OR p_max < 1 THEN RETURN true; END IF;
  SELECT count(*) INTO n FROM platform.rate_event WHERE key = left(p_key, 200) AND created_at > now() - p_window;
  IF n >= p_max THEN RETURN false; END IF;
  INSERT INTO platform.rate_event (key) VALUES (left(p_key, 200));
  RETURN true;
END $$;

-- Failed sign-ins from one network address in the window, across all e-mail addresses.
CREATE FUNCTION core.fn_recent_failures_ip(p_ip inet, p_window interval DEFAULT interval '15 minutes') RETURNS integer
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = core, public, pg_temp AS $$
  SELECT CASE WHEN p_ip IS NULL THEN 0 ELSE (SELECT count(*)::integer FROM core.login_attempt WHERE ip = p_ip AND NOT succeeded AND created_at > now() - p_window) END
$$;
CREATE INDEX IF NOT EXISTS login_attempt_ip ON core.login_attempt (ip, created_at DESC) WHERE NOT succeeded;

-- Housekeeping: counters older than two days are of no use.
CREATE FUNCTION platform.fn_rate_cleanup() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  DELETE FROM platform.rate_event WHERE created_at < now() - interval '2 days';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION platform.fn_rate_hit(text, integer, interval), core.fn_recent_failures_ip(inet, interval), platform.fn_rate_cleanup() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.fn_rate_hit(text, integer, interval), core.fn_recent_failures_ip(inet, interval) TO meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_rate_cleanup() TO meesam_worker;

COMMIT;
