-- 0040 — Record of what each user accepted at sign-up (Migration and Deployment Plan, Step 6: "sign-up consent
-- wired to the Terms of Use, Acceptable Use Policy and AI and Watch Notice"; Privacy Policy acknowledged).
-- One row per user, document and version, with the moment of acceptance. Rows are never changed or removed:
-- a new version of a document is a new row. The app role reads the signed-in user's own rows only; writing
-- goes through the function below.
BEGIN;

CREATE TABLE core.legal_acceptance (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES core.app_user(id),
  document    text NOT NULL CHECK (document IN ('terms', 'acceptable-use', 'ai-and-watch', 'privacy', 'cookies', 'pilot-agreement', 'dpa', 'pricing')),
  version     text NOT NULL,
  context     text NOT NULL CHECK (context IN ('sign_up', 'invitation', 'in_app')),
  accepted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, document, version)
);
ALTER TABLE core.legal_acceptance ENABLE ROW LEVEL SECURITY;
CREATE POLICY legal_acceptance_select ON core.legal_acceptance FOR SELECT TO meesam_app USING (user_id = platform.current_user_id());
GRANT SELECT ON core.legal_acceptance TO meesam_app;
GRANT SELECT ON core.legal_acceptance TO meesam_staff, meesam_admin, meesam_readonly;

-- Records the acceptance. Called by the web service right after it created the user (sign-up, invitation) or
-- for the signed-in user. Outside a session it is accepted only for a user created in the last hour, so the
-- function cannot be used to write acceptances for arbitrary existing users.
CREATE FUNCTION core.sp_record_consent(p_user_id uuid, p_documents text[], p_version text, p_context text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE u core.app_user; n integer;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = p_user_id;
  IF u.id IS NULL OR NOT (COALESCE(u.id = platform.current_user_id(), false) OR u.created_at > now() - interval '1 hour' OR u.status = 'invited') THEN
    RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(btrim(p_version), '') = '' THEN RAISE EXCEPTION 'version required' USING ERRCODE = '22023'; END IF;
  INSERT INTO core.legal_acceptance (user_id, document, version, context)
  SELECT u.id, d, left(p_version, 60), p_context FROM unnest(p_documents) d
  ON CONFLICT (user_id, document, version) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION core.sp_record_consent(uuid, text[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.sp_record_consent(uuid, text[], text, text) TO meesam_app;

COMMIT;
