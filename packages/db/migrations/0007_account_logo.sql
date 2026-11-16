-- 0007: account logo (personalisation). The image lives in the vault bucket under accounts/<id>/;
-- only the key is stored. The administrator uploads it from Account details.
ALTER TABLE core.account ADD COLUMN IF NOT EXISTS logo_key text NULL;

CREATE OR REPLACE FUNCTION core.fn_session(p_token_hash bytea)
RETURNS TABLE (session_id uuid, user_id uuid, account_id uuid, email citext, user_name text, role core.user_role, locale text,
               account_kind core.account_kind, account_name jsonb, verification_status core.verification_status, expires_at timestamptz,
               logo_key text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
BEGIN
  UPDATE core.session s SET last_seen_at = now()
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now() AND s.last_seen_at < now() - interval '1 minute';
  RETURN QUERY
  SELECT s.id, u.id, a.id, u.email, u.name, u.role, u.locale, a.kind, a.name, a.verification_status, s.expires_at, a.logo_key
    FROM core.session s JOIN core.app_user u ON u.id = s.user_id JOIN core.account a ON a.id = u.account_id
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now() AND u.status = 'active';
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_session(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_session(bytea) TO meesam_app, meesam_worker, meesam_admin;
