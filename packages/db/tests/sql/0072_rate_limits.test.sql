-- Tests for migration 0072: the event counter behind the limits on the sign-in pages.
BEGIN;
SET client_min_messages = warning;
SET LOCAL ROLE meesam_app;
DO $$ DECLARE denied boolean := false; BEGIN
  ASSERT platform.fn_rate_hit('t72:a', 2, interval '1 hour') AND platform.fn_rate_hit('t72:a', 2, interval '1 hour'), 'within the limit';
  ASSERT NOT platform.fn_rate_hit('t72:a', 2, interval '1 hour'), 'the third event in the window is refused';
  ASSERT platform.fn_rate_hit('t72:b', 2, interval '1 hour'), 'another key has its own count';
  ASSERT platform.fn_rate_hit(NULL, 2, interval '1 hour'), 'no key (no address known): not limited here';
  BEGIN PERFORM 1 FROM platform.rate_event; EXCEPTION WHEN insufficient_privilege THEN denied := true; END;
  ASSERT denied, 'the counter itself is not readable by the application role';
  PERFORM core.sp_login_attempt('a@x72.test', false, '203.0.113.7', 'ua'); PERFORM core.sp_login_attempt('b@x72.test', false, '203.0.113.7', 'ua'); PERFORM core.sp_login_attempt('c@x72.test', true, '203.0.113.7', 'ua');
  ASSERT core.fn_recent_failures_ip('203.0.113.7') = 2 AND core.fn_recent_failures_ip('203.0.113.8') = 0 AND core.fn_recent_failures_ip(NULL) = 0, 'failed sign-ins are counted per network address, across e-mail addresses';
END $$;
RESET ROLE;
UPDATE platform.rate_event SET created_at = now() - interval '3 days' WHERE key = 't72:a';
SET LOCAL ROLE meesam_worker;
DO $$ BEGIN ASSERT platform.fn_rate_cleanup() = 2, 'old counters are removed by housekeeping'; END $$;
RESET ROLE;
SET LOCAL ROLE meesam_app;
DO $$ BEGIN ASSERT platform.fn_rate_hit('t72:a', 2, interval '1 hour'), 'after the window the key is allowed again'; END $$;
RESET ROLE;
ROLLBACK;
\echo ALL 0072 TESTS PASSED
