-- 0033 — Removing a document from a record (raised in the Founder's staging test, 19 Nov 2026).
-- A document uploaded by mistake can be removed by an administrator of an account that may edit the record.
-- Removal is recorded, never a deletion: the row stays (removed_at, by whom), the file stays in the vault, the
-- change is audited and the other side is notified like any other change (rule 3). A removed document is no
-- longer listed or downloadable, and a removed power of attorney no longer counts for the record's POA state.
-- RULING NEEDED: who may remove a document. The System Description restricts deleting a RECORD to administrators
-- (Inferred); the same is taken for a document. The mark's own image is replaced on the Mark tab, not removed here.
BEGIN;

ALTER TABLE core.document ADD COLUMN removed_at timestamptz NULL;
ALTER TABLE core.document ADD COLUMN removed_by_user_id uuid NULL REFERENCES core.app_user(id);
ALTER TABLE core.document ADD COLUMN removed_by_account_id uuid NULL REFERENCES core.account(id);

DROP POLICY document_select ON core.document;
CREATE POLICY document_select ON core.document FOR SELECT TO meesam_app
  USING (removed_at IS NULL AND core.fn_can_access(record_id, platform.current_account_id()));

CREATE OR REPLACE FUNCTION core.fn_refresh_poa_state(p_record_id uuid) RETURNS void
LANGUAGE sql AS $$
  UPDATE core.record r SET poa_state = (
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.doc_type = 'POA' AND d.removed_at IS NULL AND (d.valid_until IS NULL OR d.valid_until >= current_date)) THEN 'present'
      WHEN EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.doc_type = 'POA' AND d.removed_at IS NULL) THEN 'expired'
      ELSE 'missing' END::core.poa_state)
  WHERE r.id = p_record_id
$$;

CREATE FUNCTION core.fn_document_remove(p_document_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); u core.app_user; d core.document;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me.id;
  IF u.id IS NULL OR u.status <> 'active' OR u.role NOT IN ('company_admin', 'agency_admin') THEN
    RAISE EXCEPTION 'only an administrator removes a document' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO d FROM core.document WHERE id = p_document_id FOR UPDATE;
  IF d.id IS NULL OR d.removed_at IS NOT NULL OR NOT core.fn_can_access(d.record_id, me.id, true) THEN
    RAISE EXCEPTION 'no such document' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM core.record r WHERE r.id = d.record_id AND r.mark_image_doc_id = d.id) THEN
    RAISE EXCEPTION 'the mark image is replaced, not removed' USING ERRCODE = '22023';
  END IF;
  UPDATE core.document SET removed_at = now(), removed_by_user_id = u.id, removed_by_account_id = me.id WHERE id = d.id;
  RETURN d.record_id;
END $$;

-- every vault name already used on a record, removed documents included, so a new upload never reuses one
CREATE FUNCTION core.fn_record_object_keys(p_record_id uuid) RETURNS SETOF text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT d.object_key FROM core.document d
   WHERE d.record_id = p_record_id AND core.fn_can_access(p_record_id, platform.current_account_id())
$$;

REVOKE EXECUTE ON FUNCTION core.fn_document_remove(uuid), core.fn_record_object_keys(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_document_remove(uuid), core.fn_record_object_keys(uuid) TO meesam_app;

COMMIT;
