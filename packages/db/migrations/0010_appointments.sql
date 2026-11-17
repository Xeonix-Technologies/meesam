-- 0010: appointments (System Description 4.4 link 1; item 38) with a closed write path.
--
-- Security correction. The 0001 policies let either party write any appointment or appointment_record row
-- that named its own account, so an agency could have created an "accepted" appointment with any owner and
-- put any record in its scope. From here the app role may only READ appointments; every change goes through
-- the functions below, which check who is calling and enforce the sequence
--   requested -> accepted | declined,  accepted -> ended.
-- The SECURITY DEFINER procedures of 0001 that take the acting account as a parameter (sp_end_appointment,
-- sp_pay, sp_certificate_received, sp_redeem_pass, sp_select_quote) are withdrawn from the app role for the
-- same reason; each gets a checked entry point when its feature is built.
BEGIN;

ALTER TABLE core.appointment ADD COLUMN IF NOT EXISTS message text NULL;
ALTER TABLE core.appointment ADD COLUMN IF NOT EXISTS decline_note text NULL;

DROP POLICY IF EXISTS appointment_all ON core.appointment;
DROP POLICY IF EXISTS appointment_record_all ON core.appointment_record;
CREATE POLICY appointment_select ON core.appointment FOR SELECT TO meesam_app
  USING (owner_account_id = platform.current_account_id() OR agency_account_id = platform.current_account_id());
CREATE POLICY appointment_record_select ON core.appointment_record FOR SELECT TO meesam_app
  USING (EXISTS (SELECT 1 FROM core.appointment a WHERE a.id = appointment_id
                  AND (a.owner_account_id = platform.current_account_id() OR a.agency_account_id = platform.current_account_id())));
REVOKE INSERT, UPDATE, DELETE ON core.appointment, core.appointment_record FROM meesam_app;

REVOKE EXECUTE ON PROCEDURE core.sp_end_appointment(uuid, core.party_side) FROM meesam_app;
DO $$
DECLARE p record;
BEGIN
  FOR p IN SELECT oid::regprocedure AS sig FROM pg_proc
            WHERE pronamespace = 'core'::regnamespace AND proname IN ('sp_pay', 'sp_certificate_received', 'sp_redeem_pass', 'sp_select_quote') LOOP
    EXECUTE format('REVOKE EXECUTE ON PROCEDURE %s FROM meesam_app', p.sig);
  END LOOP;
END $$;

-- who is calling, and what kind of account it is
CREATE FUNCTION core.fn_me() RETURNS core.account
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a core.account;
BEGIN
  SELECT * INTO a FROM core.account WHERE id = platform.current_account_id();
  IF a.id IS NULL THEN RAISE EXCEPTION 'no account in session' USING ERRCODE = '42501'; END IF;
  IF a.verified_at IS NULL THEN RAISE EXCEPTION 'account not verified' USING ERRCODE = '42501'; END IF;
  RETURN a;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_me() FROM PUBLIC;

-- puts records in an appointment's scope; only records of the owner's own families are taken
CREATE FUNCTION core.fn_appointment_scope(p_appointment_id uuid, p_owner uuid, p_record_ids uuid[]) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  INSERT INTO core.appointment_record (appointment_id, record_id)
  SELECT p_appointment_id, r.id
    FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id
   WHERE r.id = ANY (COALESCE(p_record_ids, '{}')) AND f.owner_account_id = p_owner
     AND NOT EXISTS (SELECT 1 FROM core.appointment_record x WHERE x.appointment_id = p_appointment_id AND x.record_id = r.id AND x.removed_at IS NULL);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_appointment_scope(uuid, uuid, uuid[]) FROM PUBLIC, meesam_app;

-- An owner asks an agency to act (with the records concerned), or an agency invites an owner (no records:
-- the owner chooses them on acceptance).
CREATE FUNCTION core.fn_appointment_request(p_other uuid, p_record_ids uuid[] DEFAULT NULL, p_message text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); other core.account; v_id uuid; v_owner uuid; v_agency uuid; v_side core.party_side;
BEGIN
  SELECT * INTO other FROM core.account WHERE id = p_other;
  IF other.id IS NULL OR other.verified_at IS NULL THEN RAISE EXCEPTION 'the other account is not available' USING ERRCODE = '22023'; END IF;
  IF me.kind = 'agency_office' THEN
    IF other.kind = 'agency_office' THEN RAISE EXCEPTION 'an agency invites an owner, not another agency' USING ERRCODE = '22023'; END IF;
    v_owner := other.id; v_agency := me.id; v_side := 'agency';
  ELSE
    IF other.kind <> 'agency_office' THEN RAISE EXCEPTION 'an owner appoints an agency office' USING ERRCODE = '22023'; END IF;
    v_owner := me.id; v_agency := other.id; v_side := 'owner';
  END IF;
  INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, message)
  VALUES (v_owner, v_agency, 'requested', v_side, NULLIF(left(p_message, 1000), '')) RETURNING id INTO v_id;
  IF v_side = 'owner' THEN PERFORM core.fn_appointment_scope(v_id, v_owner, p_record_ids); END IF;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (other.id, 'in_app', 'appointment_requested', jsonb_build_object('appointment_id', v_id, 'from', me.name, 'by', v_side));
  RETURN v_id;
END $$;

-- The side that did not ask answers. An owner accepting an agency's invitation names the records.
CREATE FUNCTION core.fn_appointment_respond(p_appointment_id uuid, p_accept boolean, p_record_ids uuid[] DEFAULT NULL, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); a core.appointment; v_other uuid;
BEGIN
  SELECT * INTO a FROM core.appointment WHERE id = p_appointment_id FOR UPDATE;
  IF a.id IS NULL OR a.status <> 'requested' THEN RAISE EXCEPTION 'no open request' USING ERRCODE = '22023'; END IF;
  IF NOT ((a.requested_by = 'owner' AND a.agency_account_id = me.id) OR (a.requested_by = 'agency' AND a.owner_account_id = me.id)) THEN
    RAISE EXCEPTION 'only the party that received the request may answer it' USING ERRCODE = '42501';
  END IF;
  IF p_accept THEN
    UPDATE core.appointment SET status = 'accepted', accepted_at = now() WHERE id = a.id;
    IF a.requested_by = 'agency' THEN PERFORM core.fn_appointment_scope(a.id, a.owner_account_id, p_record_ids); END IF;
  ELSE
    UPDATE core.appointment SET status = 'declined', decline_note = NULLIF(left(p_note, 500), '') WHERE id = a.id;
  END IF;
  v_other := CASE WHEN me.id = a.owner_account_id THEN a.agency_account_id ELSE a.owner_account_id END;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (v_other, 'in_app', CASE WHEN p_accept THEN 'appointment_accepted' ELSE 'appointment_declined' END,
          jsonb_build_object('appointment_id', a.id, 'from', me.name, 'note', p_note));
END $$;

-- Either party ends an accepted appointment, or withdraws its own open request. The agency loses all access at once (item 38).
CREATE FUNCTION core.fn_appointment_end(p_appointment_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); a core.appointment; v_side core.party_side;
BEGIN
  SELECT * INTO a FROM core.appointment WHERE id = p_appointment_id FOR UPDATE;
  IF a.id IS NULL OR me IS NULL OR me NOT IN (a.owner_account_id, a.agency_account_id) THEN RAISE EXCEPTION 'not a party to this appointment' USING ERRCODE = '42501'; END IF;
  IF a.status NOT IN ('requested', 'accepted') THEN RAISE EXCEPTION 'the appointment is already closed' USING ERRCODE = '22023'; END IF;
  v_side := CASE WHEN me = a.owner_account_id THEN 'owner' ELSE 'agency' END::core.party_side;
  CALL core.sp_end_appointment(a.id, v_side);
END $$;

-- The owner changes which records an accepted or requested appointment covers (per-record revoke, item 22).
CREATE FUNCTION core.fn_appointment_set_records(p_appointment_id uuid, p_record_ids uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); a core.appointment;
BEGIN
  SELECT * INTO a FROM core.appointment WHERE id = p_appointment_id FOR UPDATE;
  IF a.id IS NULL OR a.owner_account_id IS DISTINCT FROM me THEN RAISE EXCEPTION 'only the owner sets the records of an appointment' USING ERRCODE = '42501'; END IF;
  IF a.status NOT IN ('requested', 'accepted') THEN RAISE EXCEPTION 'the appointment is closed' USING ERRCODE = '22023'; END IF;
  UPDATE core.appointment_record SET removed_at = now()
   WHERE appointment_id = a.id AND removed_at IS NULL AND NOT (record_id = ANY (COALESCE(p_record_ids, '{}')));
  PERFORM core.fn_appointment_scope(a.id, a.owner_account_id, p_record_ids);
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (a.agency_account_id, 'in_app', 'appointment_scope_changed', jsonb_build_object('appointment_id', a.id));
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_appointment_request(uuid, uuid[], text), core.fn_appointment_respond(uuid, boolean, uuid[], text),
  core.fn_appointment_end(uuid), core.fn_appointment_set_records(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_appointment_request(uuid, uuid[], text), core.fn_appointment_respond(uuid, boolean, uuid[], text),
  core.fn_appointment_end(uuid), core.fn_appointment_set_records(uuid, uuid[]) TO meesam_app;

COMMIT;
