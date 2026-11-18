-- 0025 — Staff use a separate staff login (Founder ruling 18 Nov 2026, point 13; CLAUDE.md rule 11).
-- Staff are users of one internal "Meesam staff" account, never users of an owner or agency account. A staff
-- role can be held only by a user of that account. Until the first separate System Administrator has
-- activated a staff login, the earlier grant on a customer login keeps working, so nobody is locked out;
-- at that moment every staff role held by a customer login is removed.
BEGIN;

ALTER TABLE core.account ADD COLUMN IF NOT EXISTS is_staff boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS account_one_staff ON core.account ((true)) WHERE is_staff;
COMMENT ON COLUMN core.account.is_staff IS 'The single internal account whose users are Meesam staff; it owns no records and is not a customer';

-- The staff account, created on first use.
CREATE FUNCTION platform.fn_staff_account() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM core.account WHERE is_staff;
  IF v_id IS NULL THEN
    INSERT INTO core.account (kind, name, country, verified_at, verification_method, verification_status, is_staff)
    VALUES ('owner_company', '{"en": "Meesam staff", "ar": "فريق ميسم"}', 'AE', now(), 'staff', 'verified', true) RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION platform.fn_staff_account() FROM PUBLIC, meesam_app;

-- A staff role is held only by a user of the staff account (new grants; earlier grants stay until the cut-over below).
CREATE FUNCTION platform.trg_staff_role_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = NEW.user_id AND a.is_staff) THEN
    RAISE EXCEPTION 'a staff role is given only to a user of the staff account' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER staff_role_guard BEFORE INSERT ON platform.staff_role FOR EACH ROW EXECUTE FUNCTION platform.trg_staff_role_guard();

-- Invites a person as staff: a user of the staff account (invited, no password yet) holding the role.
CREATE FUNCTION platform.fn_staff_invite(p_email citext, p_name text, p_role text, p_by uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
DECLARE v_account uuid := platform.fn_staff_account(); v_id uuid;
BEGIN
  IF p_role NOT IN ('system_admin', 'watch_lead', 'publication_reviewer') THEN RAISE EXCEPTION 'unknown staff role' USING ERRCODE = '22023'; END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name is required' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM core.app_user WHERE email = p_email AND status <> 'removed') THEN
    RAISE EXCEPTION 'email already registered' USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO core.app_user (account_id, email, name, role, locale, status)
  VALUES (v_account, p_email, btrim(p_name), CASE WHEN p_role = 'system_admin' THEN 'company_admin' ELSE 'tm_manager' END::core.user_role, 'en', 'invited')
  RETURNING id INTO v_id;
  INSERT INTO platform.staff_role (user_id, role, granted_by, note) VALUES (v_id, p_role, p_by, 'invited as staff');
  RETURN v_id;
END $$;

-- Removes a staff member: roles gone, login removed, sessions closed. The last active System Administrator stays.
CREATE FUNCTION platform.fn_staff_remove(p_user_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = p_user_id AND a.is_staff AND u.status <> 'removed') THEN
    RAISE EXCEPTION 'not a staff login' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM platform.staff_role WHERE user_id = p_user_id AND role = 'system_admin')
     AND NOT EXISTS (SELECT 1 FROM platform.staff_role s JOIN core.app_user u ON u.id = s.user_id
                      WHERE s.role = 'system_admin' AND s.user_id <> p_user_id AND u.status = 'active') THEN
    RAISE EXCEPTION 'the last active System Administrator cannot be removed' USING ERRCODE = '23514';
  END IF;
  DELETE FROM platform.staff_role WHERE user_id = p_user_id;
  UPDATE core.session SET revoked_at = now() WHERE user_id = p_user_id AND revoked_at IS NULL;
  UPDATE core.verification_token SET used_at = now() WHERE user_id = p_user_id AND used_at IS NULL;
  UPDATE core.app_user SET status = 'removed' WHERE id = p_user_id;
END $$;

-- Staff as the System Admin lists them.
CREATE VIEW platform.v_staff AS
  SELECT u.id, u.email, u.name, u.status, u.last_login_at, u.created_at, u.totp_enabled_at IS NOT NULL AS totp,
         (SELECT COALESCE(array_agg(s.role ORDER BY s.role), '{}') FROM platform.staff_role s WHERE s.user_id = u.id) AS roles,
         a.is_staff AS separate_login, a.name AS account_name
    FROM core.app_user u JOIN core.account a ON a.id = u.account_id
   WHERE u.status <> 'removed' AND (a.is_staff OR EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = u.id));

REVOKE EXECUTE ON FUNCTION platform.fn_staff_invite(citext, text, text, uuid), platform.fn_staff_remove(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_staff_account(), platform.fn_staff_invite(citext, text, text, uuid), platform.fn_staff_remove(uuid) TO meesam_admin;
GRANT SELECT ON platform.v_staff TO meesam_staff, meesam_admin, meesam_readonly;

-- Cut-over: when a System Administrator's separate staff login becomes active, staff roles on customer logins end.
CREATE FUNCTION platform.trg_staff_cutover() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
BEGIN
  IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active'
     AND EXISTS (SELECT 1 FROM core.account a WHERE a.id = NEW.account_id AND a.is_staff)
     AND EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = NEW.id AND s.role = 'system_admin') THEN
    DELETE FROM platform.staff_role s USING core.app_user u, core.account a
     WHERE u.id = s.user_id AND a.id = u.account_id AND NOT a.is_staff;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER app_user_staff_cutover AFTER UPDATE OF status ON core.app_user FOR EACH ROW EXECUTE FUNCTION platform.trg_staff_cutover();

-- The session says whether the login is a staff login (as 0007, one column added).
DROP FUNCTION core.fn_session(bytea);
CREATE FUNCTION core.fn_session(p_token_hash bytea)
RETURNS TABLE (session_id uuid, user_id uuid, account_id uuid, email citext, user_name text, role core.user_role, locale text,
               account_kind core.account_kind, account_name jsonb, verification_status core.verification_status, expires_at timestamptz,
               logo_key text, is_staff boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
BEGIN
  UPDATE core.session s SET last_seen_at = now()
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now() AND s.last_seen_at < now() - interval '1 minute';
  RETURN QUERY
  SELECT s.id, u.id, a.id, u.email, u.name, u.role, u.locale, a.kind, a.name, a.verification_status, s.expires_at, a.logo_key, a.is_staff
    FROM core.session s JOIN core.app_user u ON u.id = s.user_id JOIN core.account a ON a.id = u.account_id
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now() AND u.status = 'active';
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_session(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_session(bytea) TO meesam_app, meesam_worker, meesam_admin;

-- The staff account is not a customer: it does not appear in the review queue or the list of accounts.
CREATE OR REPLACE VIEW platform.v_admin_account AS
  SELECT a.id, a.kind, a.name, a.country, a.city, a.registration_ref, a.licence_no, a.contact, a.verification_status,
         a.verified_at, a.verification_method, a.review_note, a.created_at,
         (SELECT jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role, 'status', u.status) ORDER BY u.created_at)
            FROM core.app_user u WHERE u.account_id = a.id) AS users,
         (SELECT jsonb_agg(jsonb_build_object('registry', g.code, 'ref', l.licence_ref, 'verified_at', l.verified_at) ORDER BY g.code)
            FROM core.agency_licence l JOIN registry.registry g ON g.id = l.registry_id WHERE l.account_id = a.id) AS licences,
         (SELECT count(*)::int FROM core.mark_family f JOIN core.record r ON r.mark_family_id = f.id WHERE f.owner_account_id = a.id) AS records
    FROM core.account a WHERE NOT a.is_staff;

COMMIT;
