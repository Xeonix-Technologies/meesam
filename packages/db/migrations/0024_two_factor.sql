-- 0024 — Two-factor sign-in (Founder ruling 18 Nov 2026, point 12): both methods — a code from an
-- authenticator app (TOTP, RFC 6238) and a code sent by e-mail — required for Meesam staff and for account
-- administrators, optional for other users.
--
-- After the password is accepted no session is opened yet: a short-lived sign-in challenge is created and the
-- session opens only when the second factor is given. The authenticator secret and the challenge are never
-- readable by the app role (0011 grants it named columns of core.app_user only); everything goes through the
-- functions below.
BEGIN;

ALTER TABLE core.app_user
  ADD COLUMN IF NOT EXISTS totp_secret text NULL,            -- base32; set once the user has confirmed a code
  ADD COLUMN IF NOT EXISTS totp_pending_secret text NULL,    -- during set-up, before the first code is confirmed
  ADD COLUMN IF NOT EXISTS totp_enabled_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS totp_last_step bigint NULL,       -- a code is accepted once (no replay within its window)
  ADD COLUMN IF NOT EXISTS two_factor_opt_in boolean NOT NULL DEFAULT false;   -- users for whom it is optional
GRANT SELECT (totp_enabled_at, two_factor_opt_in) ON core.app_user TO meesam_app;

CREATE TABLE core.login_challenge (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash   bytea NOT NULL UNIQUE,                        -- hash of the value kept in the browser's cookie
  user_id      uuid NOT NULL REFERENCES core.app_user(id),
  code_hash    bytea NULL,                                   -- hash of the e-mail code, when one was sent
  code_sent_at timestamptz NULL,
  attempts     smallint NOT NULL DEFAULT 0,
  expires_at   timestamptz NOT NULL,
  consumed_at  timestamptz NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.login_challenge (user_id, created_at);
ALTER TABLE core.login_challenge ENABLE ROW LEVEL SECURITY;  -- no policy: invisible to the app role
REVOKE ALL ON core.login_challenge FROM meesam_app;

-- Whether a user must give a second factor, and which methods they have.
-- Required: account administrators (company or agency). Optional: everyone else, by their own choice.
CREATE FUNCTION core.fn_2fa_state(p_user_id uuid) RETURNS TABLE (required boolean, totp boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT (u.role IN ('company_admin', 'agency_admin') AND a.kind <> 'owner_individual')
         OR u.two_factor_opt_in OR u.totp_enabled_at IS NOT NULL
         OR EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = u.id),
         u.totp_enabled_at IS NOT NULL
    FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = p_user_id
$$;

-- Opens a sign-in challenge after the password was accepted (15 minutes).
CREATE FUNCTION core.sp_2fa_begin(p_user_id uuid, p_token_hash bytea) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  DELETE FROM core.login_challenge WHERE expires_at < now() - interval '1 day';
  INSERT INTO core.login_challenge (token_hash, user_id, expires_at) VALUES (p_token_hash, p_user_id, now() + interval '15 minutes') RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- The open challenge behind a browser cookie: who it is for and what can be used.
CREATE FUNCTION core.fn_2fa_challenge(p_token_hash bytea)
RETURNS TABLE (user_id uuid, email citext, name text, locale text, totp boolean, code_sent_at timestamptz, verification_status core.verification_status)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT u.id, u.email, u.name, u.locale, u.totp_enabled_at IS NOT NULL, c.code_sent_at, a.verification_status
    FROM core.login_challenge c JOIN core.app_user u ON u.id = c.user_id JOIN core.account a ON a.id = u.account_id
   WHERE c.token_hash = p_token_hash AND c.consumed_at IS NULL AND c.expires_at > now() AND c.attempts < 6 AND u.status = 'active'
$$;

-- Records the e-mail code just sent (one per minute; valid for the life of the challenge).
CREATE FUNCTION core.sp_2fa_email_code(p_token_hash bytea, p_code_hash bytea) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  UPDATE core.login_challenge SET code_hash = p_code_hash, code_sent_at = now()
   WHERE token_hash = p_token_hash AND consumed_at IS NULL AND expires_at > now()
     AND (code_sent_at IS NULL OR code_sent_at < now() - interval '1 minute');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END $$;

-- Checks an e-mail code. Every wrong try counts; six tries close the challenge. Returns the user on success.
CREATE FUNCTION core.sp_2fa_check_email(p_token_hash bytea, p_code_hash bytea) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE c core.login_challenge;
BEGIN
  SELECT * INTO c FROM core.login_challenge WHERE token_hash = p_token_hash AND consumed_at IS NULL AND expires_at > now() AND attempts < 6 FOR UPDATE;
  IF c.id IS NULL THEN RETURN NULL; END IF;
  IF c.code_hash IS NOT NULL AND c.code_hash = p_code_hash THEN
    UPDATE core.login_challenge SET consumed_at = now() WHERE id = c.id;
    RETURN c.user_id;
  END IF;
  UPDATE core.login_challenge SET attempts = attempts + 1 WHERE id = c.id;
  RETURN NULL;
END $$;

-- The authenticator secret for an open challenge, for the server to check a code against (never sent to the browser).
CREATE FUNCTION core.fn_2fa_totp_secret(p_token_hash bytea) RETURNS TABLE (secret text, last_step bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT u.totp_secret, u.totp_last_step FROM core.login_challenge c JOIN core.app_user u ON u.id = c.user_id
   WHERE c.token_hash = p_token_hash AND c.consumed_at IS NULL AND c.expires_at > now() AND c.attempts < 6 AND u.totp_enabled_at IS NOT NULL
$$;

-- Result of the server's check of an authenticator code: accepted at a time step (once only), or a wrong try.
CREATE FUNCTION core.sp_2fa_totp_result(p_token_hash bytea, p_step bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE c core.login_challenge; n integer;
BEGIN
  SELECT * INTO c FROM core.login_challenge WHERE token_hash = p_token_hash AND consumed_at IS NULL AND expires_at > now() AND attempts < 6 FOR UPDATE;
  IF c.id IS NULL THEN RETURN NULL; END IF;
  IF p_step IS NULL THEN
    UPDATE core.login_challenge SET attempts = attempts + 1 WHERE id = c.id;
    RETURN NULL;
  END IF;
  UPDATE core.app_user SET totp_last_step = p_step WHERE id = c.user_id AND totp_enabled_at IS NOT NULL AND (totp_last_step IS NULL OR totp_last_step < p_step);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    UPDATE core.login_challenge SET attempts = attempts + 1 WHERE id = c.id;      -- a code already used
    RETURN NULL;
  END IF;
  UPDATE core.login_challenge SET consumed_at = now() WHERE id = c.id;
  RETURN c.user_id;
END $$;

-- Set-up by the signed-in user: keep a new secret pending, read it back to show, confirm it, or remove the app.
CREATE FUNCTION core.sp_totp_pending(p_secret text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  UPDATE core.app_user SET totp_pending_secret = p_secret WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;
CREATE FUNCTION core.fn_totp_pending() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT totp_pending_secret FROM core.app_user WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;
CREATE FUNCTION core.sp_totp_confirm(p_step bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  UPDATE core.app_user SET totp_secret = totp_pending_secret, totp_pending_secret = NULL, totp_enabled_at = now(), totp_last_step = p_step
   WHERE id = platform.current_user_id() AND account_id = platform.current_account_id() AND totp_pending_secret IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END $$;
CREATE FUNCTION core.sp_totp_remove() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  UPDATE core.app_user SET totp_secret = NULL, totp_pending_secret = NULL, totp_enabled_at = NULL, totp_last_step = NULL
   WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;
-- Users for whom two-factor is optional switch it on or off themselves (the e-mail code then applies).
CREATE FUNCTION core.sp_2fa_opt(p_on boolean) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  UPDATE core.app_user SET two_factor_opt_in = COALESCE(p_on, false) WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;

REVOKE EXECUTE ON FUNCTION core.fn_2fa_state(uuid), core.sp_2fa_begin(uuid, bytea), core.fn_2fa_challenge(bytea), core.sp_2fa_email_code(bytea, bytea),
  core.sp_2fa_check_email(bytea, bytea), core.fn_2fa_totp_secret(bytea), core.sp_2fa_totp_result(bytea, bigint),
  core.sp_totp_pending(text), core.fn_totp_pending(), core.sp_totp_confirm(bigint), core.sp_totp_remove(), core.sp_2fa_opt(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_2fa_state(uuid), core.sp_2fa_begin(uuid, bytea), core.fn_2fa_challenge(bytea), core.sp_2fa_email_code(bytea, bytea),
  core.sp_2fa_check_email(bytea, bytea), core.fn_2fa_totp_secret(bytea), core.sp_2fa_totp_result(bytea, bigint),
  core.sp_totp_pending(text), core.fn_totp_pending(), core.sp_totp_confirm(bigint), core.sp_totp_remove(), core.sp_2fa_opt(boolean) TO meesam_app;

COMMIT;
