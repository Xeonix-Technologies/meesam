-- 0071 — Two-step sign-in secrets are sealed under a key of their own (Founder ruling R13, 21 Nov 2026).
-- The web service now stores the authenticator secret encrypted (AES-256-GCM, key TWO_FACTOR_KEY, kept apart from
-- the database). A secret stored before the key existed is plain; this function lets the server replace it with the
-- sealed form at the moment its owner signs in with a correct code, and only then: the open sign-in challenge and the
-- old value must both match. Nothing else about the sign-in changes.
BEGIN;

CREATE FUNCTION core.sp_2fa_totp_seal(p_token_hash bytea, p_old text, p_new text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF p_new IS NULL OR p_new !~ '^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' THEN RAISE EXCEPTION 'not a sealed value' USING ERRCODE = '22023'; END IF;
  UPDATE core.app_user u SET totp_secret = p_new
    FROM core.login_challenge c
   WHERE c.token_hash = p_token_hash AND c.consumed_at IS NULL AND c.expires_at > now() AND c.attempts < 6
     AND u.id = c.user_id AND u.totp_enabled_at IS NOT NULL AND u.totp_secret = p_old AND u.totp_secret NOT LIKE 'v1.%';
  RETURN FOUND;
END $$;
REVOKE EXECUTE ON FUNCTION core.sp_2fa_totp_seal(bytea, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.sp_2fa_totp_seal(bytea, text, text) TO meesam_app;

COMMIT;
