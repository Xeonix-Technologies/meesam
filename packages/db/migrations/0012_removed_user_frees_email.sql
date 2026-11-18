-- 0012 — A removed user frees the e-mail address (Founder ruling 18 Nov 2026).
-- An e-mail still belongs to one account at a time (item 38), but only among users that are not removed:
-- once an administrator removes a user, the same person can be invited into another account or register one.
-- The removed row stays, with its e-mail, for the history of what that user did.
BEGIN;

ALTER TABLE core.app_user DROP CONSTRAINT app_user_email_key;
CREATE UNIQUE INDEX app_user_email_live ON core.app_user (email) WHERE status <> 'removed';

-- Sign-in and look-up by e-mail see the live user only.
CREATE OR REPLACE FUNCTION core.fn_user_by_email(p_email citext) RETURNS uuid
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = core, public, pg_temp AS $$
  SELECT id FROM core.app_user WHERE email = p_email AND status <> 'removed'
$$;

CREATE OR REPLACE FUNCTION core.fn_user_for_login(p_email citext)
RETURNS TABLE (user_id uuid, account_id uuid, password_hash text, user_status core.user_status, verification_status core.verification_status, locale text)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = core, public, pg_temp AS $$
  SELECT u.id, u.account_id, u.password_hash, u.status, a.verification_status, u.locale
    FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.email = p_email AND u.status <> 'removed'
$$;

CREATE OR REPLACE FUNCTION core.sp_login_attempt(p_email citext, p_succeeded boolean, p_ip inet, p_user_agent text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  INSERT INTO core.login_attempt (email, account_id, user_id, succeeded, ip, user_agent)
  VALUES (p_email, (SELECT account_id FROM core.app_user WHERE email = p_email AND status <> 'removed'),
          (SELECT id FROM core.app_user WHERE email = p_email AND status <> 'removed'), p_succeeded, p_ip, left(p_user_agent, 400))
$$;

-- Sign-up: as 0004, except that an address held only by removed users is free.
CREATE OR REPLACE FUNCTION core.sp_register_account(p jsonb, OUT account_id uuid, OUT user_id uuid)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'platform', 'registry', 'public', 'pg_temp'
AS $function$
DECLARE v_kind core.account_kind := (p ->> 'kind')::core.account_kind; v_role core.user_role; lic jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM core.app_user WHERE email = (p -> 'user' ->> 'email')::citext AND status <> 'removed') THEN
    RAISE EXCEPTION 'email already registered' USING ERRCODE = 'unique_violation';
  END IF;
  v_role := CASE v_kind WHEN 'agency_office' THEN 'agency_admin'::core.user_role ELSE 'company_admin' END;
  INSERT INTO core.account (kind, name, country, city, registration_ref, contact, languages_served, verification_status)
  VALUES (v_kind, p -> 'name', p ->> 'country', p ->> 'city', p ->> 'registration_ref',
          COALESCE(p -> 'contact', '{}'::jsonb),
          CASE WHEN p ? 'languages_served' THEN ARRAY(SELECT jsonb_array_elements_text(p -> 'languages_served')) END,
          'pending_email')
  RETURNING id INTO account_id;
  INSERT INTO core.app_user (account_id, email, name, role, locale, status, password_hash)
  VALUES (account_id, (p -> 'user' ->> 'email')::citext, p -> 'user' ->> 'name', v_role,
          COALESCE(p -> 'user' ->> 'locale', 'en'), 'invited', p -> 'user' ->> 'password_hash')
  RETURNING id INTO user_id;
  IF v_kind = 'agency_office' AND p ? 'licences' THEN
    FOR lic IN SELECT * FROM jsonb_array_elements(p -> 'licences') LOOP
      INSERT INTO core.agency_licence (account_id, registry_id, licence_ref)
      SELECT account_id, g.id, lic ->> 'licence_ref' FROM registry.registry g WHERE g.code = lic ->> 'registry_code'
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;
END $function$
;

-- Invitation: as 0011, except that a removed user is no longer re-used; the person gets a new user row.
CREATE OR REPLACE FUNCTION core.fn_user_invite(p_email citext, p_name text, p_role core.user_role, p_locale text DEFAULT 'en') RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.app_user := core.fn_admin_me(); v_id uuid;
BEGIN
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name is required' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM core.app_user WHERE email = p_email AND status <> 'removed') THEN
    RAISE EXCEPTION 'email already registered' USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO core.app_user (account_id, email, name, role, locale, status)
  VALUES (me.account_id, p_email, btrim(p_name), p_role, COALESCE(p_locale, 'en'), 'invited') RETURNING id INTO v_id;
  RETURN v_id;
END $$;

COMMIT;
