-- 0038 — Two-step sign-in can be switched on or off by the user (Founder ruling 19 Nov 2026).
-- Until now it was fixed on for the administrators of company and agency accounts (ruling 12, 18 Nov) and
-- optional for other users. Now every customer user has a switch on the Account page. Where the user has
-- not chosen, the earlier default stands: on for those administrators, off for the others.
-- Staff logins are not given the switch: a staff role reaches every account, so it stays on for them.
BEGIN;

ALTER TABLE core.app_user ADD COLUMN two_factor_choice boolean NULL;   -- NULL = no choice made: the default for the role applies

CREATE OR REPLACE FUNCTION core.fn_2fa_state(p_user_id uuid) RETURNS TABLE (required boolean, totp boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = u.id) OR a.is_staff
         OR COALESCE(u.two_factor_choice,
                     (u.role IN ('company_admin', 'agency_admin') AND a.kind <> 'owner_individual') OR u.two_factor_opt_in OR u.totp_enabled_at IS NOT NULL),
         u.totp_enabled_at IS NOT NULL
    FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = p_user_id
$$;

-- the signed-in user's own switch
CREATE OR REPLACE FUNCTION core.sp_2fa_opt(p_on boolean) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  UPDATE core.app_user SET two_factor_choice = COALESCE(p_on, false), two_factor_opt_in = COALESCE(p_on, false)
   WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;

COMMIT;
