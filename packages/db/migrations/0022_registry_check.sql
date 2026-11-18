-- 0022 — "Verified with registry" is self-declared (Founder ruling 18 Nov 2026, point 16).
-- There is no registry connection in this version, so the owner or the agency managing the record states
-- that they compared it with the registry's own record; Meesam keeps who and when. The statement is
-- withdrawn automatically when certificate information changes afterwards. When a registry feed exists the
-- same fields are filled from it.
BEGIN;

ALTER TABLE core.record
  ADD COLUMN IF NOT EXISTS registry_checked_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS registry_checked_by_user_id uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN IF NOT EXISTS registry_checked_by jsonb NULL;        -- {user, account} as named at the time: the other side cannot read this account's users
COMMENT ON COLUMN core.record.registry_checked_at IS 'When a user last stated the record matches the registry''s own record (self-declared, item 16 of the 18 Nov 2026 rulings)';

-- A check no longer stands once the numbers or dates it covered are changed.
CREATE FUNCTION core.trg_record_registry_check_reset() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.registry_checked_at IS NOT NULL AND NEW.registry_checked_at IS NOT DISTINCT FROM OLD.registry_checked_at
     AND (NEW.application_no, NEW.filing_date, NEW.registration_no, NEW.registration_date, NEW.expiry_date)
         IS DISTINCT FROM (OLD.application_no, OLD.filing_date, OLD.registration_no, OLD.registration_date, OLD.expiry_date) THEN
    NEW.registry_checked_at := NULL; NEW.registry_checked_by_user_id := NULL; NEW.registry_checked_by := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER record_registry_check_reset BEFORE UPDATE ON core.record FOR EACH ROW EXECUTE FUNCTION core.trg_record_registry_check_reset();

-- States (or withdraws) that the record was compared with the registry. Row-level security decides who may
-- change the record; a Viewer does not.
CREATE FUNCTION core.fn_record_registry_check(p_record_id uuid, p_checked boolean) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE u_name text; u_role core.user_role; a_name jsonb;
BEGIN
  SELECT u.name, u.role, a.name INTO u_name, u_role, a_name FROM core.app_user u JOIN core.account a ON a.id = u.account_id
   WHERE u.id = platform.current_user_id() AND u.account_id = platform.current_account_id();
  IF u_name IS NULL OR u_role = 'viewer' THEN RAISE EXCEPTION 'this user does not state a registry check' USING ERRCODE = '42501'; END IF;
  IF COALESCE(p_checked, false) THEN
    UPDATE core.record SET registry_checked_at = now(), registry_checked_by_user_id = platform.current_user_id(),
                           registry_checked_by = jsonb_build_object('user', u_name, 'account', a_name) WHERE id = p_record_id;
  ELSE
    UPDATE core.record SET registry_checked_at = NULL, registry_checked_by_user_id = NULL, registry_checked_by = NULL WHERE id = p_record_id;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_record_registry_check(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_record_registry_check(uuid, boolean) TO meesam_app;

COMMIT;
