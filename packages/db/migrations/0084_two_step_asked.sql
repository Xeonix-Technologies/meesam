-- 0084 — Two-step sign-in is offered once, after signing in (Founder ruling 23 Nov 2026).
-- A person who has set a password from an invitation now signs in like everyone else (the web sends them to the
-- log-in page), and a login that has not yet chosen is asked once, after signing in, whether to use two-step
-- sign-in and how: a code by e-mail, or an authenticator app. The answer is the user's own switch (0038); this
-- migration only records that the question was put, so it is put once.
--   asked when: never asked, no authenticator app, and either no choice made yet or a staff login (for staff the
--   second step is always on, so the question there is only "by e-mail or by app").
BEGIN;

ALTER TABLE core.app_user ADD COLUMN two_factor_asked_at timestamptz NULL;
COMMENT ON COLUMN core.app_user.two_factor_asked_at IS 'when the user was asked, after signing in, whether and how to use two-step sign-in; NULL = not asked yet';

CREATE FUNCTION core.fn_2fa_ask(p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT COALESCE((
    SELECT u.two_factor_asked_at IS NULL AND u.totp_enabled_at IS NULL AND u.status = 'active'
           AND (u.two_factor_choice IS NULL OR a.is_staff OR EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = u.id))
      FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = p_user_id), false)
$$;

-- the signed-in user's own answer was given (whatever it was)
CREATE FUNCTION core.sp_2fa_asked() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  UPDATE core.app_user SET two_factor_asked_at = COALESCE(two_factor_asked_at, now())
   WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;

REVOKE EXECUTE ON FUNCTION core.fn_2fa_ask(uuid), core.sp_2fa_asked() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_2fa_ask(uuid), core.sp_2fa_asked() TO meesam_app;

COMMIT;
