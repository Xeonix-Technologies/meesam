-- 0013 — Who is told by e-mail about an appointment event (System Description, Notifications: the
-- Administrator receives everything; an Agent or Trademark manager too where no assignment exists;
-- a Viewer receives nothing by default).
-- The app role cannot read the users of another account, so the other side's recipients come from this
-- function, which answers only for an appointment the caller is a party to.
BEGIN;

CREATE FUNCTION core.fn_appointment_recipients(p_appointment_id uuid)
RETURNS TABLE (email citext, name text, locale text, account_name jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); a core.appointment; v_other uuid;
BEGIN
  SELECT * INTO a FROM core.appointment WHERE id = p_appointment_id;
  IF a.id IS NULL OR me IS NULL OR me NOT IN (a.owner_account_id, a.agency_account_id) THEN
    RAISE EXCEPTION 'not a party to this appointment' USING ERRCODE = '42501';
  END IF;
  v_other := CASE WHEN me = a.owner_account_id THEN a.agency_account_id ELSE a.owner_account_id END;
  RETURN QUERY
  SELECT u.email, u.name, u.locale, o.name FROM core.app_user u JOIN core.account o ON o.id = u.account_id
   WHERE u.account_id = v_other AND u.status = 'active' AND u.role <> 'viewer';
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_appointment_recipients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_appointment_recipients(uuid) TO meesam_app;

COMMIT;
