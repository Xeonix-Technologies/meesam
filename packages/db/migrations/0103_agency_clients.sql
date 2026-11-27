-- 0103 — An agency's own client list (Founder ruling 27 Nov 2026: a "Client" column in the bulk import; Meesam
-- matches it to the agency's client list and creates the missing clients).
-- A client here is a name the agency keeps for its own filing: the party a trademark it entered belongs to, while
-- that party has no Meesam account. It is what the account entered, nothing more: not an account, not a login, not
-- a verified owner, and never shown to another account. When the owner later redeems a pass the trademark moves
-- to the owner's account as before (0015) and the agency then sees the owner's own name.
-- Two spellings of one name are one client: the name is compared without letter case, punctuation or spaces
-- ("Al-Noor Trading L.L.C." and "AL NOOR TRADING LLC" are the same client).
BEGIN;

CREATE FUNCTION core.fn_client_key(p_name text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT regexp_replace(lower(COALESCE(p_name, '')), '[[:space:].,;:''"()_/&-]+', '', 'g')
$$;

CREATE TABLE core.client (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         uuid NOT NULL REFERENCES core.account(id),
  name               text NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 300),
  name_key           text NOT NULL CHECK (name_key <> ''),
  created_by_user_id uuid NULL REFERENCES core.app_user(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, name_key)
);
ALTER TABLE core.client ENABLE ROW LEVEL SECURITY;
CREATE POLICY client_select ON core.client FOR SELECT TO meesam_app USING (account_id = platform.current_account_id());
GRANT SELECT ON core.client TO meesam_app;
GRANT SELECT ON core.client TO meesam_admin, meesam_readonly;
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON core.client FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row();

ALTER TABLE core.mark_family ADD COLUMN client_id uuid NULL REFERENCES core.client(id);
CREATE INDEX ON core.mark_family (client_id) WHERE client_id IS NOT NULL;
COMMENT ON COLUMN core.mark_family.client_id IS 'the agency''s own client this mark was entered for (core.client); read by that agency only';

-- A family is attached only to a client of the account that is acting.
CREATE FUNCTION core.trg_family_client() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF NEW.client_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.client_id IS DISTINCT FROM OLD.client_id)
     AND platform.current_account_id() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM core.client c WHERE c.id = NEW.client_id AND c.account_id = platform.current_account_id()) THEN
    RAISE EXCEPTION 'the client is not in this account''s list' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER family_client BEFORE INSERT OR UPDATE OF client_id ON core.mark_family FOR EACH ROW EXECUTE FUNCTION core.trg_family_client();

-- The client with this name in the caller's list, created when it is not there yet. Agency offices only.
CREATE FUNCTION core.fn_client_ensure(p_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v_account uuid := platform.current_account_id(); v_key text := core.fn_client_key(p_name); v_id uuid;
BEGIN
  IF v_account IS NULL OR NOT EXISTS (SELECT 1 FROM core.account a WHERE a.id = v_account AND a.kind = 'agency_office' AND NOT a.is_staff) THEN
    RAISE EXCEPTION 'only an agency office keeps a client list' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_key = '' THEN RETURN NULL; END IF;
  INSERT INTO core.client (account_id, name, name_key, created_by_user_id)
  VALUES (v_account, left(btrim(regexp_replace(p_name, '[[:space:]]+', ' ', 'g')), 300), v_key, platform.current_user_id())
  ON CONFLICT (account_id, name_key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN SELECT id INTO v_id FROM core.client WHERE account_id = v_account AND name_key = v_key; END IF;
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_client_ensure(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_client_ensure(text) TO meesam_app;
GRANT EXECUTE ON FUNCTION core.fn_client_key(text) TO meesam_app, meesam_staff, meesam_admin, meesam_worker;

-- The caller's client list with the number of trademarks under each name.
CREATE FUNCTION core.fn_clients() RETURNS TABLE (id uuid, name text, marks integer, created_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT c.id, c.name, (SELECT count(*)::int FROM core.mark_family f JOIN core.record r ON r.mark_family_id = f.id
                         WHERE f.client_id = c.id AND f.owner_account_id = c.account_id), c.created_at
    FROM core.client c ORDER BY c.name
$$;
GRANT EXECUTE ON FUNCTION core.fn_clients() TO meesam_app;

COMMIT;
