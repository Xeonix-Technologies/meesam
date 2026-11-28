-- 0110 — Removing a trademark that was never activated (Founder ruling 28 Nov 2026).
-- Until now a record could only be closed (withdrawn, cancelled, refused, expired), never taken out of a
-- portfolio; a mark entered by mistake, or loaded with a wrong number, stayed for good and kept its number.
-- Ruled:
--   * only a mark that was never activated can be removed: nothing was paid and Meesam never worked for it;
--     an activated mark is closed through a stage change, as before, never removed;
--   * only the administrator of the account the mark belongs to (an agency holding it under an appointment or
--     an instruction does not remove its client's mark);
--   * the number is free again, for this or another account;
--   * it stays in the audit record: who removed it and when.
-- How: the row is kept and marked (removed_at), as documents are (0033) and as the Data Architecture asks
-- (Section 14.10: audit events are the record's legal history and are never discarded; documents are kept).
-- A removed record is out of the one source of access (core.v_record_access), so every page, list, count,
-- reminder and comparison loses it at once; its documents stay in the vault, unseen. The two unique rules on
-- records count live records only.
BEGIN;

ALTER TABLE core.record
  ADD COLUMN removed_at            timestamptz NULL,
  ADD COLUMN removed_by_user_id    uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN removed_by_account_id uuid NULL REFERENCES core.account(id);
COMMENT ON COLUMN core.record.removed_at IS 'taken out of its portfolio by the account''s administrator while never activated (0110); the row and its audit history are kept';

-- a registry''s number belongs to one live record; a removed record no longer holds it
DROP INDEX core.record_one_per_application;
CREATE UNIQUE INDEX record_one_per_application ON core.record (registry_id, application_no) WHERE application_no IS NOT NULL AND removed_at IS NULL;
DROP INDEX core.record_one_per_family_registry;
CREATE UNIQUE INDEX record_one_per_family_registry ON core.record (mark_family_id, registry_id) WHERE madrid IS NULL AND removed_at IS NULL;

-- who holds a record (0027), live records only
CREATE OR REPLACE FUNCTION core.fn_holds_record(p_record_id uuid, p_account_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id AND r.removed_at IS NULL AND f.owner_account_id = p_account_id)
      OR EXISTS (SELECT 1 FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
                   JOIN core.record r ON r.id = ar.record_id AND r.removed_at IS NULL
                  WHERE ar.record_id = p_record_id AND a.agency_account_id = p_account_id AND a.status = 'accepted' AND a.ended_at IS NULL)
$$;

-- the one source of access (0027), live records only
CREATE OR REPLACE VIEW core.v_record_access (record_id, account_id, via, can_edit) AS
  SELECT r.id, f.owner_account_id, 'owner'::text, true
    FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id
   WHERE r.removed_at IS NULL
  UNION ALL
  SELECT ar.record_id, a.agency_account_id, 'appointment', true
    FROM core.appointment a
    JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
    JOIN core.record r ON r.id = ar.record_id AND r.removed_at IS NULL
   WHERE a.status = 'accepted' AND a.ended_at IS NULL
  UNION ALL
  SELECT i.record_id, i.to_account_id, 'cross_border', true
    FROM core.cross_border_instruction i
   WHERE i.status = 'active' AND core.fn_holds_record(i.record_id, i.from_account_id);

-- the record's own visibility rule (0006) lets the owner see a row through the mark family as well; live rows only
DROP POLICY record_select ON core.record;
CREATE POLICY record_select ON core.record FOR SELECT TO meesam_app
  USING (removed_at IS NULL AND (core.fn_family_owner(mark_family_id) = platform.current_account_id()
                                 OR core.fn_can_access(id, platform.current_account_id())));

-- the marks waiting for activation (0104), live records only
CREATE OR REPLACE FUNCTION core.fn_my_inactive() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT r.id FROM core.mark_family f JOIN core.record r ON r.mark_family_id = f.id
   WHERE f.owner_account_id = platform.current_account_id() AND r.activated_at IS NULL AND NOT r.terminal AND r.removed_at IS NULL
  UNION
  SELECT r.id FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
    JOIN core.record r ON r.id = ar.record_id
   WHERE a.agency_account_id = platform.current_account_id() AND a.status = 'accepted' AND a.ended_at IS NULL AND r.activated_at IS NULL AND NOT r.terminal AND r.removed_at IS NULL
$$;

-- the application role never writes the removal columns itself
CREATE FUNCTION core.trg_record_removal() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user = 'meesam_app' AND (TG_OP = 'INSERT' AND NEW.removed_at IS NOT NULL
       OR TG_OP = 'UPDATE' AND (NEW.removed_at IS DISTINCT FROM OLD.removed_at OR NEW.removed_by_user_id IS DISTINCT FROM OLD.removed_by_user_id
                                OR NEW.removed_by_account_id IS DISTINCT FROM OLD.removed_by_account_id)) THEN
    RAISE EXCEPTION 'a record is removed through core.fn_record_remove only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER record_removal BEFORE INSERT OR UPDATE OF removed_at, removed_by_user_id, removed_by_account_id ON core.record
  FOR EACH ROW EXECUTE FUNCTION core.trg_record_removal();

-- Removes one record. Errors: 42501 not the account's administrator; 22023 no such record of this account;
-- 55000 the record was activated or paid and is closed by a stage change instead.
CREATE FUNCTION core.fn_record_remove(p_record_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v_account uuid := platform.current_account_id(); u core.app_user; r core.record;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = v_account;
  IF u.id IS NULL OR u.status <> 'active' OR u.role NOT IN ('company_admin', 'agency_admin') THEN
    RAISE EXCEPTION 'only the account''s administrator removes a trademark' USING ERRCODE = '42501';
  END IF;
  SELECT x.* INTO r FROM core.record x JOIN core.mark_family f ON f.id = x.mark_family_id
   WHERE x.id = p_record_id AND x.removed_at IS NULL AND f.owner_account_id = v_account FOR UPDATE OF x;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'no such trademark of this account' USING ERRCODE = '22023';
  END IF;
  IF r.activated_at IS NOT NULL OR r.paid_state = 'paid' OR EXISTS (SELECT 1 FROM core.payment p WHERE p.record_id = r.id) THEN
    RAISE EXCEPTION 'an activated or paid trademark is closed by a stage change, not removed' USING ERRCODE = '55000';
  END IF;
  UPDATE core.record SET removed_at = now(), removed_by_user_id = u.id, removed_by_account_id = v_account,
                         activation_requested_at = NULL, activation_requested_by = NULL
   WHERE id = r.id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_record_remove(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_record_remove(uuid) TO meesam_app;

COMMIT;
