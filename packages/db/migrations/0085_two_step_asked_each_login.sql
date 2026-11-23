-- 0085 — The two-step question is put at every sign-in until the person says "don't ask me again"
-- (Founder ruling 23 Nov 2026, replacing the "once" of 0084): for every login, existing or new, whatever was
-- chosen before. It is not put to a login that has an authenticator app set up (there is nothing left to offer),
-- and it stops when the person ticks "don't ask me again" (sp_2fa_asked, unchanged). The choice itself stays
-- changeable under Account.
BEGIN;

CREATE OR REPLACE FUNCTION core.fn_2fa_ask(p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT COALESCE((
    SELECT u.two_factor_asked_at IS NULL AND u.totp_enabled_at IS NULL AND u.status = 'active'
      FROM core.app_user u WHERE u.id = p_user_id), false)
$$;
COMMENT ON COLUMN core.app_user.two_factor_asked_at IS 'when the user said "don''t ask me again" to the two-step question put after signing in; NULL = still asked';

COMMIT;
