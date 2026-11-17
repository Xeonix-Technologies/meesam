-- 0009: staff roles (Staff Services and Pages v0.1, Section 2; CLAUDE.md rule 11). A staff role is granted to
-- a user; the two staff areas (Meesam System Admin, Watch Operations Console) open only to users who hold one.
-- Roles: system_admin, watch_lead, publication_reviewer. The table is not visible to meesam_app; the web
-- reads a user's roles through fn_staff_roles and writes through sp_grant_staff / sp_revoke_staff (admin role).
BEGIN;

CREATE TABLE platform.staff_role (
  user_id     uuid NOT NULL REFERENCES core.app_user(id),
  role        text NOT NULL CHECK (role IN ('system_admin', 'watch_lead', 'publication_reviewer')),
  granted_at  timestamptz NOT NULL DEFAULT now(),
  granted_by  uuid NULL REFERENCES core.app_user(id),
  note        text NULL,
  PRIMARY KEY (user_id, role)
);
ALTER TABLE platform.staff_role ENABLE ROW LEVEL SECURITY;   -- no policy for meesam_app: invisible to customers
REVOKE ALL ON platform.staff_role FROM meesam_app;
GRANT SELECT ON platform.staff_role TO meesam_staff, meesam_readonly;
GRANT SELECT, INSERT, DELETE ON platform.staff_role TO meesam_admin;

CREATE FUNCTION platform.fn_staff_roles(p_user_id uuid) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
  SELECT COALESCE(array_agg(role ORDER BY role), '{}') FROM platform.staff_role WHERE user_id = p_user_id
$$;
REVOKE EXECUTE ON FUNCTION platform.fn_staff_roles(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform.fn_staff_roles(uuid) TO meesam_app, meesam_staff, meesam_admin, meesam_worker;

CREATE PROCEDURE platform.sp_grant_staff(p_user_id uuid, p_role text, p_by uuid DEFAULT NULL, p_note text DEFAULT NULL)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
  INSERT INTO platform.staff_role (user_id, role, granted_by, note) VALUES (p_user_id, p_role, p_by, p_note)
  ON CONFLICT (user_id, role) DO NOTHING
$$;
CREATE PROCEDURE platform.sp_revoke_staff(p_user_id uuid, p_role text)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
  DELETE FROM platform.staff_role WHERE user_id = p_user_id AND role = p_role
$$;
REVOKE EXECUTE ON PROCEDURE platform.sp_grant_staff(uuid, text, uuid, text), platform.sp_revoke_staff(uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON PROCEDURE platform.sp_grant_staff(uuid, text, uuid, text), platform.sp_revoke_staff(uuid, text) TO meesam_admin;

-- Accounts as the System Admin sees them (review queue and directory of accounts).
CREATE VIEW platform.v_admin_account AS
  SELECT a.id, a.kind, a.name, a.country, a.city, a.registration_ref, a.licence_no, a.contact, a.verification_status,
         a.verified_at, a.verification_method, a.review_note, a.created_at,
         (SELECT jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'role', u.role, 'status', u.status) ORDER BY u.created_at)
            FROM core.app_user u WHERE u.account_id = a.id) AS users,
         (SELECT jsonb_agg(jsonb_build_object('registry', g.code, 'ref', l.licence_ref, 'verified_at', l.verified_at) ORDER BY g.code)
            FROM core.agency_licence l JOIN registry.registry g ON g.id = l.registry_id WHERE l.account_id = a.id) AS licences,
         (SELECT count(*)::int FROM core.mark_family f JOIN core.record r ON r.mark_family_id = f.id WHERE f.owner_account_id = a.id) AS records
    FROM core.account a;
GRANT SELECT ON platform.v_admin_account TO meesam_staff, meesam_admin, meesam_readonly;

COMMIT;
