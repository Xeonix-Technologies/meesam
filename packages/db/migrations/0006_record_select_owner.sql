-- 0006: the record SELECT policy must recognise the owner through the mark family, not only through
-- core.v_record_access. fn_can_access is STABLE and sees the statement's starting snapshot, so an
-- INSERT ... RETURNING on core.record (RETURNING is checked against the SELECT policy) could not see
-- the row it had just created and failed with "new row violates row-level security policy".
DROP POLICY IF EXISTS record_select ON core.record;
CREATE POLICY record_select ON core.record FOR SELECT TO meesam_app
  USING (core.fn_family_owner(mark_family_id) = platform.current_account_id()
         OR core.fn_can_access(id, platform.current_account_id()));
