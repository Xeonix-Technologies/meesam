-- =============================================================================
-- Meesam — migration 0004: accounts, sign-up, sessions, verification (Step 3.2)
-- Sources: Owner Services and Pages v0.1 Section 3.1 (owner registration, verification, 7 Nov 2026),
-- Agency Services and Pages v0.1 Section 3.1 (agency registration, licence per registry, directory
-- listing off until verified), System Description items 2–6, 38, 39; Data Architecture Section 6.
-- RULING NEEDED: no document names the login mechanism. Narrowest reading implemented: e-mail and
-- password (scrypt hash kept in core.app_user.password_hash), e-mail verification link, server-side
-- sessions in an httpOnly cookie. Passwordless links, UAE Pass or a second factor are additions
-- to this schema, not replacements.
-- =============================================================================
BEGIN;

CREATE TYPE core.verification_status AS ENUM ('pending_email', 'pending_review', 'verified', 'rejected');
CREATE TYPE core.token_purpose AS ENUM ('email_verify', 'password_reset', 'invite');

ALTER TABLE core.account
  ADD COLUMN verification_status core.verification_status NOT NULL DEFAULT 'pending_email',
  ADD COLUMN review_note text NULL,
  ADD COLUMN reviewed_by_user_id uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN registration_ref text NULL,            -- trade licence / registration reference (company)
  ADD COLUMN city text NULL,
  ADD COLUMN languages_served text[] NULL;          -- agency: languages served (directory)
UPDATE core.account SET verification_status = 'verified' WHERE verified_at IS NOT NULL;
-- verified_at and verification_status always agree, whichever one a writer sets
CREATE OR REPLACE FUNCTION core.trg_account_verification_sync() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.verified_at IS NOT NULL AND NEW.verification_status <> 'verified' THEN NEW.verification_status := 'verified'; END IF;
  IF NEW.verification_status = 'verified' AND NEW.verified_at IS NULL THEN NEW.verified_at := now(); END IF;
  IF NEW.verification_status <> 'verified' THEN NEW.verified_at := NULL; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER account_verification_sync BEFORE INSERT OR UPDATE OF verified_at, verification_status ON core.account
  FOR EACH ROW EXECUTE FUNCTION core.trg_account_verification_sync();
CREATE INDEX ON core.account (verification_status) WHERE verification_status = 'pending_review';

-- Agency licence per registry (Agency Services 3.1, 3.15). Directory listing needs at least one verified licence.
CREATE TABLE core.agency_licence (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES core.account(id),
  registry_id   uuid NOT NULL REFERENCES registry.registry(id),
  licence_ref   text NOT NULL,
  document_key  text NULL,                         -- vault object key once uploaded (Step 3.4)
  verified_at   timestamptz NULL,
  verified_by_user_id uuid NULL REFERENCES core.app_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, registry_id)
);
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON core.agency_licence FOR EACH ROW EXECUTE FUNCTION platform.touch_updated_at();
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON core.agency_licence FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row();
ALTER TABLE core.agency_licence ENABLE ROW LEVEL SECURITY;
CREATE POLICY agency_licence_all ON core.agency_licence FOR ALL TO meesam_app
  USING (account_id = platform.current_account_id()) WITH CHECK (account_id = platform.current_account_id());
GRANT SELECT, INSERT, UPDATE ON core.agency_licence TO meesam_app;

-- Sessions: token is random, only its SHA-256 is stored. Never read by meesam_app directly.
CREATE TABLE core.session (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES core.app_user(id),
  account_id   uuid NOT NULL REFERENCES core.account(id),
  token_hash   bytea NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz NULL,
  ip           inet NULL,
  user_agent   text NULL
);
CREATE INDEX ON core.session (user_id) WHERE revoked_at IS NULL;
ALTER TABLE core.session ENABLE ROW LEVEL SECURITY;

CREATE TABLE core.verification_token (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES core.app_user(id),
  purpose    core.token_purpose NOT NULL,
  token_hash bytea NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.verification_token (user_id, purpose) WHERE used_at IS NULL;
ALTER TABLE core.verification_token ENABLE ROW LEVEL SECURITY;

-- Account activity source (Owner 3.17 / Agency 3.18): logins and failed logins.
CREATE TABLE core.login_attempt (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email      citext NOT NULL,
  account_id uuid NULL REFERENCES core.account(id),
  user_id    uuid NULL REFERENCES core.app_user(id),
  succeeded  boolean NOT NULL,
  ip         inet NULL,
  user_agent text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.login_attempt (email, created_at DESC);
CREATE INDEX ON core.login_attempt (account_id, created_at DESC);
ALTER TABLE core.login_attempt ENABLE ROW LEVEL SECURITY;
CREATE POLICY login_attempt_admin_select ON core.login_attempt FOR SELECT TO meesam_app
  USING (account_id = platform.current_account_id()
         AND EXISTS (SELECT 1 FROM core.app_user u WHERE u.id = platform.current_user_id() AND u.role IN ('company_admin', 'agency_admin')));
GRANT SELECT ON core.login_attempt TO meesam_app;

-- -----------------------------------------------------------------------------
-- Procedures the web app calls before any account context exists (SECURITY DEFINER).
-- -----------------------------------------------------------------------------

-- Sign-up (owner individual / owner company / agency). p = {
--   kind, name {ar,en}, country, city, registration_ref, contact {mobile,...}, languages_served [],
--   user: {email, name, locale, password_hash}, licences: [{registry_code, licence_ref}] }
CREATE OR REPLACE FUNCTION core.sp_register_account(p jsonb, OUT account_id uuid, OUT user_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE v_kind core.account_kind := (p ->> 'kind')::core.account_kind; v_role core.user_role; lic jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM core.app_user WHERE email = (p -> 'user' ->> 'email')::citext) THEN
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
END $$;

CREATE OR REPLACE FUNCTION core.sp_issue_token(p_user_id uuid, p_purpose core.token_purpose, p_token_hash bytea, p_ttl interval DEFAULT interval '24 hours')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  -- one live token per purpose; issuing a new one voids the older
  UPDATE core.verification_token SET used_at = now() WHERE user_id = p_user_id AND purpose = p_purpose AND used_at IS NULL;
  INSERT INTO core.verification_token (user_id, purpose, token_hash, expires_at) VALUES (p_user_id, p_purpose, p_token_hash, now() + p_ttl) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Consumes a token. email_verify: user active, account moves to Meesam review. Returns the user id or NULL.
CREATE OR REPLACE FUNCTION core.sp_consume_token(p_token_hash bytea, p_purpose core.token_purpose) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE t core.verification_token; v_account uuid;
BEGIN
  SELECT * INTO t FROM core.verification_token WHERE token_hash = p_token_hash AND purpose = p_purpose FOR UPDATE;
  IF t.id IS NULL OR t.used_at IS NOT NULL OR t.expires_at < now() THEN RETURN NULL; END IF;
  UPDATE core.verification_token SET used_at = now() WHERE id = t.id;
  IF p_purpose = 'email_verify' THEN
    UPDATE core.app_user SET status = 'active' WHERE id = t.user_id AND status = 'invited' RETURNING account_id INTO v_account;
    IF v_account IS NULL THEN SELECT account_id INTO v_account FROM core.app_user WHERE id = t.user_id; END IF;
    UPDATE core.account SET verification_status = 'pending_review' WHERE id = v_account AND verification_status = 'pending_email';
  END IF;
  RETURN t.user_id;
END $$;

CREATE OR REPLACE FUNCTION core.sp_set_password(p_user_id uuid, p_password_hash text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  UPDATE core.app_user SET password_hash = p_password_hash WHERE id = p_user_id;
  UPDATE core.session SET revoked_at = now() WHERE user_id = p_user_id AND revoked_at IS NULL;
$$;

-- Credentials lookup for the login handler (the hash is compared in the application).
CREATE OR REPLACE FUNCTION core.fn_user_for_login(p_email citext)
RETURNS TABLE (user_id uuid, account_id uuid, password_hash text, user_status core.user_status, verification_status core.verification_status, locale text)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = core, public, pg_temp AS $$
  SELECT u.id, u.account_id, u.password_hash, u.status, a.verification_status, u.locale
    FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.email = p_email
$$;

CREATE OR REPLACE FUNCTION core.fn_user_by_email(p_email citext) RETURNS uuid
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = core, public, pg_temp AS $$
  SELECT id FROM core.app_user WHERE email = p_email
$$;

CREATE OR REPLACE FUNCTION core.sp_login_attempt(p_email citext, p_succeeded boolean, p_ip inet, p_user_agent text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  INSERT INTO core.login_attempt (email, account_id, user_id, succeeded, ip, user_agent)
  VALUES (p_email, (SELECT account_id FROM core.app_user WHERE email = p_email), (SELECT id FROM core.app_user WHERE email = p_email),
          p_succeeded, p_ip, left(p_user_agent, 400))
$$;

-- Throttle helper: failed attempts for an e-mail in the last window (the edge rate limit is the first line).
CREATE OR REPLACE FUNCTION core.fn_recent_failures(p_email citext, p_window interval DEFAULT interval '15 minutes') RETURNS integer
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = core, public, pg_temp AS $$
  SELECT count(*)::integer FROM core.login_attempt WHERE email = p_email AND NOT succeeded AND created_at > now() - p_window
$$;

CREATE OR REPLACE FUNCTION core.sp_session_create(p_user_id uuid, p_token_hash bytea, p_ttl interval, p_ip inet, p_user_agent text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
DECLARE v_id uuid; v_account uuid;
BEGIN
  SELECT account_id INTO v_account FROM core.app_user WHERE id = p_user_id;
  INSERT INTO core.session (user_id, account_id, token_hash, expires_at, ip, user_agent)
  VALUES (p_user_id, v_account, p_token_hash, now() + p_ttl, p_ip, left(p_user_agent, 400)) RETURNING id INTO v_id;
  UPDATE core.app_user SET last_login_at = now() WHERE id = p_user_id;
  RETURN v_id;
END $$;

-- Resolves a cookie token to the signed-in user; touches last_seen at most once a minute.
CREATE OR REPLACE FUNCTION core.fn_session(p_token_hash bytea)
RETURNS TABLE (session_id uuid, user_id uuid, account_id uuid, email citext, user_name text, role core.user_role, locale text,
               account_kind core.account_kind, account_name jsonb, verification_status core.verification_status, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
BEGIN
  UPDATE core.session s SET last_seen_at = now()
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now() AND s.last_seen_at < now() - interval '1 minute';
  RETURN QUERY
  SELECT s.id, u.id, a.id, u.email, u.name, u.role, u.locale, a.kind, a.name, a.verification_status, s.expires_at
    FROM core.session s JOIN core.app_user u ON u.id = s.user_id JOIN core.account a ON a.id = u.account_id
   WHERE s.token_hash = p_token_hash AND s.revoked_at IS NULL AND s.expires_at > now() AND u.status = 'active';
END $$;

CREATE OR REPLACE FUNCTION core.sp_session_revoke(p_token_hash bytea) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  UPDATE core.session SET revoked_at = now() WHERE token_hash = p_token_hash AND revoked_at IS NULL
$$;

-- Meesam staff (or the AI check) decides the review; the account's users are told (item 39).
CREATE OR REPLACE PROCEDURE core.sp_review_account(p_account_id uuid, p_approve boolean, p_method core.verification_method, p_by_user_id uuid, p_note text DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF p_approve THEN
    UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = p_method,
                            reviewed_by_user_id = p_by_user_id, review_note = p_note WHERE id = p_account_id;
    UPDATE core.agency_licence SET verified_at = COALESCE(verified_at, now()), verified_by_user_id = COALESCE(verified_by_user_id, p_by_user_id)
     WHERE account_id = p_account_id;
  ELSE
    UPDATE core.account SET verification_status = 'rejected', reviewed_by_user_id = p_by_user_id, review_note = p_note WHERE id = p_account_id;
  END IF;
  INSERT INTO platform.notification (account_id, user_id, channel, kind, payload)
  SELECT p_account_id, u.id, c.channel, CASE WHEN p_approve THEN 'account_verified' ELSE 'account_rejected' END,
         jsonb_build_object('note', p_note)
    FROM core.app_user u CROSS JOIN (VALUES ('in_app'::platform.notification_channel), ('email')) c(channel)
   WHERE u.account_id = p_account_id AND u.status = 'active';
END $$;

-- Grants: the web app may call the sign-in path functions; the review procedure is staff/admin only.
GRANT EXECUTE ON FUNCTION core.sp_register_account(jsonb), core.sp_issue_token(uuid, core.token_purpose, bytea, interval),
  core.sp_consume_token(bytea, core.token_purpose), core.sp_set_password(uuid, text), core.fn_user_for_login(citext),
  core.fn_user_by_email(citext), core.sp_login_attempt(citext, boolean, inet, text), core.fn_recent_failures(citext, interval),
  core.sp_session_create(uuid, bytea, interval, inet, text), core.fn_session(bytea), core.sp_session_revoke(bytea)
  TO meesam_app, meesam_worker, meesam_admin;
REVOKE EXECUTE ON PROCEDURE core.sp_review_account(uuid, boolean, core.verification_method, uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON PROCEDURE core.sp_review_account(uuid, boolean, core.verification_method, uuid, text) TO meesam_staff, meesam_admin, meesam_worker;

-- Pending notifications that need sending by e-mail are picked up by the worker (3.6); the
-- account_verified mail is queued here so the activation flow is complete from day one.
COMMIT;
