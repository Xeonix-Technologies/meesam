-- 0011 — Users and roles inside an account (System Description Section 3 roles table, items 38 and 39;
-- "Company accounts: invite users, assign roles", Ruled).
--
-- Closes the write path on core.app_user: 0001 let every user of an account insert and update any user row of
-- that account (including roles) and read the password hashes of colleagues. From here the app role reads the
-- non-secret columns of its own account's users, updates only its own name and language, and every other
-- change goes through the functions below, which check that the caller is the account's administrator.
BEGIN;

DROP POLICY IF EXISTS app_user_all ON core.app_user;
CREATE POLICY app_user_select ON core.app_user FOR SELECT TO meesam_app USING (account_id = platform.current_account_id());
CREATE POLICY app_user_update_self ON core.app_user FOR UPDATE TO meesam_app
  USING (id = platform.current_user_id() AND account_id = platform.current_account_id())
  WITH CHECK (id = platform.current_user_id() AND account_id = platform.current_account_id());
REVOKE SELECT, INSERT, UPDATE, DELETE ON core.app_user FROM meesam_app;
GRANT SELECT (id, account_id, email, name, role, locale, status, last_login_at, created_at, updated_at) ON core.app_user TO meesam_app;
GRANT UPDATE (name, locale) ON core.app_user TO meesam_app;

-- The signed-in user's own password hash (to check the current password before a change).
CREATE FUNCTION core.fn_my_password_hash() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT password_hash FROM core.app_user WHERE id = platform.current_user_id() AND account_id = platform.current_account_id()
$$;

-- The caller, if it is an active administrator of a verified company or agency account; raises otherwise.
CREATE FUNCTION core.fn_admin_me() RETURNS core.app_user
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE u core.app_user; a core.account;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = platform.current_account_id();
  IF u.id IS NULL OR u.status <> 'active' OR u.role NOT IN ('company_admin', 'agency_admin') THEN
    RAISE EXCEPTION 'only the account administrator manages users' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO a FROM core.account WHERE id = u.account_id;
  IF a.verified_at IS NULL THEN RAISE EXCEPTION 'account not verified' USING ERRCODE = '42501'; END IF;
  IF a.kind = 'owner_individual' THEN RAISE EXCEPTION 'an individual owner account has one user' USING ERRCODE = '22023'; END IF;
  RETURN u;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_admin_me() FROM PUBLIC, meesam_app;

-- Invites a person into the caller's account. The role must fit the account kind (trigger of 0001).
-- An e-mail belongs to one account platform-wide (item 38): an address already in use is refused, except a
-- user this same account removed earlier, who is invited again.
CREATE FUNCTION core.fn_user_invite(p_email citext, p_name text, p_role core.user_role, p_locale text DEFAULT 'en') RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.app_user := core.fn_admin_me(); x core.app_user; v_id uuid;
BEGIN
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name is required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO x FROM core.app_user WHERE email = p_email;
  IF x.id IS NOT NULL THEN
    IF x.account_id = me.account_id AND x.status = 'removed' THEN
      UPDATE core.app_user SET status = 'invited', password_hash = NULL, name = btrim(p_name), role = p_role, locale = COALESCE(p_locale, 'en') WHERE id = x.id;
      RETURN x.id;
    END IF;
    RAISE EXCEPTION 'email already registered' USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO core.app_user (account_id, email, name, role, locale, status)
  VALUES (me.account_id, p_email, btrim(p_name), p_role, COALESCE(p_locale, 'en'), 'invited') RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- The invited user, for (re)sending the invitation; NULL unless it is an open invitation in the caller's account.
CREATE FUNCTION core.fn_user_invited(p_user_id uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.app_user := core.fn_admin_me();
BEGIN
  RETURN (SELECT id FROM core.app_user WHERE id = p_user_id AND account_id = me.account_id AND status = 'invited' AND password_hash IS NULL);
END $$;

-- An account always keeps at least one active administrator.
CREATE FUNCTION core.fn_user_guard_last_admin(p_account uuid, p_except uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM core.app_user WHERE account_id = p_account AND id <> p_except AND status = 'active'
                    AND role IN ('company_admin', 'agency_admin')) THEN
    RAISE EXCEPTION 'the account must keep one active administrator' USING ERRCODE = '23514';
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_user_guard_last_admin(uuid, uuid) FROM PUBLIC, meesam_app;

CREATE FUNCTION core.fn_user_set_role(p_user_id uuid, p_role core.user_role) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.app_user := core.fn_admin_me(); x core.app_user;
BEGIN
  SELECT * INTO x FROM core.app_user WHERE id = p_user_id AND account_id = me.account_id FOR UPDATE;
  IF x.id IS NULL OR x.status = 'removed' THEN RAISE EXCEPTION 'no such user in this account' USING ERRCODE = '22023'; END IF;
  IF x.role IN ('company_admin', 'agency_admin') AND p_role NOT IN ('company_admin', 'agency_admin') THEN
    PERFORM core.fn_user_guard_last_admin(me.account_id, x.id);
  END IF;
  UPDATE core.app_user SET role = p_role WHERE id = x.id;
  INSERT INTO platform.notification (account_id, user_id, channel, kind, payload)
  VALUES (me.account_id, x.id, 'in_app', 'user_role_changed', jsonb_build_object('role', p_role, 'by', me.name));
END $$;

-- Suspend, reactivate or remove a user. Suspending or removing closes that user's sessions at once.
CREATE FUNCTION core.fn_user_set_status(p_user_id uuid, p_status core.user_status) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.app_user := core.fn_admin_me(); x core.app_user;
BEGIN
  IF p_status NOT IN ('active', 'suspended', 'removed') THEN RAISE EXCEPTION 'status not allowed' USING ERRCODE = '22023'; END IF;
  SELECT * INTO x FROM core.app_user WHERE id = p_user_id AND account_id = me.account_id FOR UPDATE;
  IF x.id IS NULL OR x.status = 'removed' THEN RAISE EXCEPTION 'no such user in this account' USING ERRCODE = '22023'; END IF;
  IF x.id = me.id THEN RAISE EXCEPTION 'an administrator does not suspend or remove their own login' USING ERRCODE = '22023'; END IF;
  IF p_status = 'active' THEN
    IF x.status <> 'suspended' THEN RAISE EXCEPTION 'only a suspended user is reactivated' USING ERRCODE = '22023'; END IF;
  ELSE
    IF x.status = 'active' AND x.role IN ('company_admin', 'agency_admin') THEN PERFORM core.fn_user_guard_last_admin(me.account_id, x.id); END IF;
    UPDATE core.session SET revoked_at = now() WHERE user_id = x.id AND revoked_at IS NULL;
    UPDATE core.verification_token SET used_at = now() WHERE user_id = x.id AND used_at IS NULL;
  END IF;
  -- an invitation never accepted has no password: suspending it is the same as removing it
  UPDATE core.app_user SET status = CASE WHEN p_status = 'suspended' AND x.password_hash IS NULL THEN 'removed' ELSE p_status END WHERE id = x.id;
END $$;

-- The invited person sets a password with the token from the invitation e-mail and becomes active.
CREATE FUNCTION core.sp_accept_invite(p_token_hash bytea, p_password_hash text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE t core.verification_token; v_id uuid;
BEGIN
  SELECT * INTO t FROM core.verification_token WHERE token_hash = p_token_hash AND purpose = 'invite' FOR UPDATE;
  IF t.id IS NULL OR t.used_at IS NOT NULL OR t.expires_at < now() THEN RETURN NULL; END IF;
  UPDATE core.app_user SET status = 'active', password_hash = p_password_hash
   WHERE id = t.user_id AND status = 'invited' AND password_hash IS NULL RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN NULL; END IF;
  UPDATE core.verification_token SET used_at = now() WHERE id = t.id;
  RETURN v_id;
END $$;

-- Who invited, for the invitation page (name of the account and the invited person), by token.
CREATE FUNCTION core.fn_invite_preview(p_token_hash bytea) RETURNS TABLE (user_name text, email citext, account_name jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT u.name, u.email, a.name FROM core.verification_token t JOIN core.app_user u ON u.id = t.user_id JOIN core.account a ON a.id = u.account_id
   WHERE t.token_hash = p_token_hash AND t.purpose = 'invite' AND t.used_at IS NULL AND t.expires_at > now() AND u.status = 'invited'
$$;

REVOKE EXECUTE ON FUNCTION core.fn_my_password_hash(), core.fn_user_invite(citext, text, core.user_role, text), core.fn_user_invited(uuid),
  core.fn_user_set_role(uuid, core.user_role), core.fn_user_set_status(uuid, core.user_status),
  core.sp_accept_invite(bytea, text), core.fn_invite_preview(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_my_password_hash(), core.fn_user_invite(citext, text, core.user_role, text), core.fn_user_invited(uuid),
  core.fn_user_set_role(uuid, core.user_role), core.fn_user_set_status(uuid, core.user_status),
  core.sp_accept_invite(bytea, text), core.fn_invite_preview(bytea) TO meesam_app;

COMMIT;
