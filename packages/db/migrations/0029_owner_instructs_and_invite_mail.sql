-- 0029 — Founder rulings 19 Nov 2026:
--  (a) an owner can send an instruction to an agency office on one of its own trademarks (0027 allowed agency
--      offices only). The office the owner instructed is known to the owner, and the two can write to each other
--      on the record's message thread. An office instructed by an AGENCY stays hidden from the owner (item 26).
--  (b) an Agent, not only the Administrator, accepts or declines an instruction. Ending stays with the Administrator.
--  (c) when an invitation turns into an appointment request, the owner is told by e-mail as well, unless the
--      inviting office switched that off (owner_invite.notify_owner).
--  (d) the limit of 50 invitations per office in 24 hours is confirmed (may be reviewed later).
BEGIN;

-- ---------------------------------------------------------------- (a) + (b) instructions
-- who acts on an instruction: an active user of a verified account that is not staff
CREATE FUNCTION core.fn_instruction_actor(p_admin_only boolean DEFAULT false) RETURNS core.account
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); u core.app_user; ok boolean;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me.id;
  IF u.id IS NULL OR u.status <> 'active' OR me.is_staff THEN RAISE EXCEPTION 'not allowed for this user' USING ERRCODE = '42501'; END IF;
  ok := CASE WHEN me.kind = 'agency_office' THEN u.role = 'agency_admin' OR (NOT p_admin_only AND u.role = 'agent')
             ELSE u.role = 'company_admin' OR (NOT p_admin_only AND u.role <> 'viewer') END;
  IF NOT ok THEN RAISE EXCEPTION 'not allowed for this user' USING ERRCODE = '42501'; END IF;
  RETURN me;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_instruction_actor(boolean) FROM PUBLIC, meesam_app;

-- The owner of a trademark, or an agency office holding it, instructs an agency office on it.
CREATE OR REPLACE FUNCTION core.fn_instruction_request(p_record_id uuid, p_to uuid DEFAULT NULL, p_to_email citext DEFAULT NULL, p_message text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_instruction_actor(); o core.account; v_id uuid;
BEGIN
  IF NOT core.fn_holds_record(p_record_id, me.id) THEN
    RAISE EXCEPTION 'only the owner or an office holding the record instructs an office on it' USING ERRCODE = '42501';
  END IF;
  IF p_to IS NOT NULL THEN
    SELECT * INTO o FROM core.account WHERE id = p_to;
  ELSIF p_to_email IS NOT NULL THEN
    SELECT a.* INTO o FROM core.app_user u JOIN core.account a ON a.id = u.account_id
     WHERE u.email = btrim(p_to_email::text)::citext AND u.status = 'active';
  END IF;
  IF o.id IS NULL OR o.kind <> 'agency_office' OR o.verified_at IS NULL OR o.is_staff OR o.id = me.id THEN
    RAISE EXCEPTION 'the other office is not available' USING ERRCODE = '22023';
  END IF;
  INSERT INTO core.cross_border_instruction (from_account_id, to_account_id, record_id, status, message, requested_by_user_id)
  VALUES (me.id, o.id, p_record_id, 'requested', NULLIF(left(btrim(COALESCE(p_message, '')), 1000), ''), platform.current_user_id())
  RETURNING id INTO v_id;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (o.id, 'in_app', 'instruction_requested', jsonb_build_object('instruction_id', v_id, 'from', me.name));
  RETURN v_id;
END $$;

-- The instructed office accepts or declines: its Administrator or an Agent (ruling 19 Nov).
CREATE OR REPLACE FUNCTION core.fn_instruction_respond(p_instruction_id uuid, p_accept boolean, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_agency_actor(false); i core.cross_border_instruction;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id FOR UPDATE;
  IF i.id IS NULL OR i.to_account_id <> me.id THEN RAISE EXCEPTION 'only the instructed office answers' USING ERRCODE = '42501'; END IF;
  IF i.status <> 'requested' THEN RAISE EXCEPTION 'no open instruction' USING ERRCODE = '22023'; END IF;
  IF p_accept THEN
    UPDATE core.cross_border_instruction SET status = 'active', accepted_at = now() WHERE id = i.id;
  ELSE
    UPDATE core.cross_border_instruction SET status = 'declined', decline_note = NULLIF(left(btrim(COALESCE(p_note, '')), 500), ''), ended_at = now() WHERE id = i.id;
  END IF;
  INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
  VALUES (i.from_account_id, 'in_app', CASE WHEN p_accept THEN 'instruction_accepted' ELSE 'instruction_declined' END, i.record_id,
          jsonb_build_object('instruction_id', i.id, 'from', me.name, 'note', p_note));
END $$;

-- Either side's Administrator ends an instruction in force, or the sender's withdraws one still waiting.
CREATE OR REPLACE FUNCTION core.fn_instruction_end(p_instruction_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_instruction_actor(true); i core.cross_border_instruction;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id FOR UPDATE;
  IF i.id IS NULL OR me.id NOT IN (i.from_account_id, i.to_account_id) THEN RAISE EXCEPTION 'not a party to this instruction' USING ERRCODE = '42501'; END IF;
  IF i.status NOT IN ('requested', 'active') THEN RAISE EXCEPTION 'the instruction is already closed' USING ERRCODE = '22023'; END IF;
  UPDATE core.cross_border_instruction SET status = 'ended', ended_at = now(), ended_by_account_id = me.id WHERE id = i.id;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (CASE WHEN me.id = i.from_account_id THEN i.to_account_id ELSE i.from_account_id END, 'in_app', 'instruction_ended',
          jsonb_build_object('instruction_id', i.id, 'from', me.name));
END $$;

-- The other side's users who are told by e-mail (every active user except a Viewer).
CREATE OR REPLACE FUNCTION core.fn_instruction_recipients(p_instruction_id uuid)
RETURNS TABLE (email citext, name text, locale text, account_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); i core.cross_border_instruction; v_other uuid;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id;
  IF i.id IS NULL OR me IS NULL OR me NOT IN (i.from_account_id, i.to_account_id) THEN RAISE EXCEPTION 'not a party to this instruction' USING ERRCODE = '42501'; END IF;
  v_other := CASE WHEN me = i.from_account_id THEN i.to_account_id ELSE i.from_account_id END;
  RETURN QUERY SELECT u.email, u.name, u.locale, u.account_id FROM core.app_user u
                WHERE u.account_id = v_other AND u.status = 'active' AND u.role <> 'viewer';
END $$;

-- Messages: the agencies on a record's thread are those holding it under an appointment and, now, an office
-- the OWNER instructed directly on it. An office instructed by an agency is not on the owner's thread.
CREATE OR REPLACE FUNCTION core.fn_holding_agencies(p_record_id uuid) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT DISTINCT a.agency_account_id FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id
   WHERE ar.record_id = p_record_id AND ar.removed_at IS NULL AND a.status = 'accepted' AND a.ended_at IS NULL
  UNION
  SELECT i.to_account_id FROM core.cross_border_instruction i JOIN core.record r ON r.id = i.record_id JOIN core.mark_family f ON f.id = r.mark_family_id
   WHERE i.record_id = p_record_id AND i.status = 'active' AND i.from_account_id = f.owner_account_id
$$;

-- Whom the caller can write to on a record's thread: for the owner, the agencies above; for one of those
-- agencies, itself (it writes to the owner). Empty for anybody else.
CREATE FUNCTION core.fn_message_parties(p_record_id uuid) RETURNS TABLE (id uuid, name jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT a.id, a.name FROM core.fn_holding_agencies(p_record_id) x JOIN core.account a ON a.id = x
   WHERE x = platform.current_account_id()
      OR platform.current_account_id() = (SELECT f.owner_account_id FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id)
   ORDER BY a.id
$$;
REVOKE EXECUTE ON FUNCTION core.fn_message_parties(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_message_parties(uuid) TO meesam_app;

-- ---------------------------------------------------------------- (c) e-mail to the owner when an invitation becomes a request
ALTER TABLE core.owner_invite ADD COLUMN notify_owner boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION core.fn_owner_invites_convert(p_account_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a core.account; i core.owner_invite; g core.account; v_id uuid; n integer := 0; v_new boolean;
BEGIN
  SELECT * INTO a FROM core.account WHERE id = p_account_id;
  IF a.id IS NULL OR a.verified_at IS NULL OR a.kind = 'agency_office' OR a.is_staff THEN RETURN 0; END IF;
  FOR i IN SELECT v.* FROM core.owner_invite v
            WHERE v.status = 'pending'
              AND v.email IN (SELECT u.email FROM core.app_user u WHERE u.account_id = a.id AND u.status = 'active')
            ORDER BY v.created_at FOR UPDATE OF v LOOP
    SELECT * INTO g FROM core.account WHERE id = i.agency_account_id;
    v_new := false;
    SELECT id INTO v_id FROM core.appointment
     WHERE owner_account_id = a.id AND agency_account_id = g.id AND status IN ('requested', 'accepted');
    IF v_id IS NULL AND g.verified_at IS NOT NULL THEN
      INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, message)
      VALUES (a.id, g.id, 'requested', 'agency', i.message) RETURNING id INTO v_id;
      v_new := true;
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (a.id, 'in_app', 'appointment_requested', jsonb_build_object('appointment_id', v_id, 'from', g.name, 'by', 'agency'));
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (g.id, 'in_app', 'owner_invite_joined', jsonb_build_object('appointment_id', v_id, 'email', i.email::text));
    END IF;
    IF v_new AND i.notify_owner THEN
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (a.id, 'email', 'invite_request_mail', jsonb_build_object('appointment_id', v_id, 'agency', g.name, 'note', i.message));
    END IF;
    UPDATE core.owner_invite SET status = 'converted', appointment_id = v_id, closed_at = now() WHERE id = i.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Hands the queued owner e-mails to the web service, one row per mail and active user of the owner account.
CREATE FUNCTION platform.fn_invite_request_mails_take()
RETURNS TABLE (email citext, name text, locale text, account_id uuid, appointment_id uuid, agency jsonb, note text)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
  WITH taken AS (
    UPDATE platform.notification n SET status = 'sent', sent_at = now()
     WHERE n.channel = 'email' AND n.status = 'queued' AND n.kind = 'invite_request_mail'
    RETURNING n.account_id, n.payload)
  SELECT u.email, u.name, u.locale, u.account_id, (t.payload ->> 'appointment_id')::uuid, t.payload -> 'agency', t.payload ->> 'note'
    FROM taken t JOIN core.app_user u ON u.account_id = t.account_id
   WHERE u.status = 'active' AND u.role <> 'viewer'
$$;
REVOKE EXECUTE ON FUNCTION platform.fn_invite_request_mails_take() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_invite_request_mails_take() TO meesam_staff, meesam_admin;

-- The agency's entry point, with the choice whether the owner is e-mailed when the request reaches their account.
DROP FUNCTION core.fn_owner_invite(citext, text);
CREATE FUNCTION core.fn_owner_invite(p_email citext, p_message text DEFAULT NULL, p_notify_owner boolean DEFAULT true,
                                     OUT outcome text, OUT appointment_id uuid, OUT invite_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); v_user uuid := platform.current_user_id(); v_email citext := btrim(p_email::text)::citext;
        o core.account; v_msg text := NULLIF(left(btrim(COALESCE(p_message, '')), 1000), ''); v core.owner_invite;
        v_notify boolean := COALESCE(p_notify_owner, true);
BEGIN
  IF me.kind <> 'agency_office' THEN RAISE EXCEPTION 'only an agency office invites an owner' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.app_user WHERE id = v_user AND account_id = me.id AND status = 'active' AND role IN ('agency_admin', 'agent')) THEN
    RAISE EXCEPTION 'only the administrator or an agent invites an owner' USING ERRCODE = '42501';
  END IF;
  IF v_email::text !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email::text) > 254 THEN RAISE EXCEPTION 'not an e-mail address' USING ERRCODE = '22023'; END IF;
  -- Founder ruling 19 Nov 2026: 50 invitations per office in 24 hours, against bulk mail; may be reviewed later.
  IF (SELECT count(*) FROM core.owner_invite WHERE agency_account_id = me.id AND created_at > now() - interval '24 hours') >= 50 THEN
    RAISE EXCEPTION 'invitation limit reached' USING ERRCODE = '54000';
  END IF;

  SELECT a.* INTO o FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.email = v_email AND u.status <> 'removed';
  IF o.id IS NOT NULL AND (o.kind = 'agency_office' OR o.is_staff) THEN
    RAISE EXCEPTION 'the address does not belong to an owner' USING ERRCODE = '22023';
  END IF;

  IF o.id IS NOT NULL AND o.verified_at IS NOT NULL
     AND EXISTS (SELECT 1 FROM core.app_user u WHERE u.email = v_email AND u.status = 'active') THEN
    INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, message)
    VALUES (o.id, me.id, 'requested', 'agency', v_msg) RETURNING id INTO appointment_id;
    INSERT INTO platform.notification (account_id, channel, kind, payload)
    VALUES (o.id, 'in_app', 'appointment_requested', jsonb_build_object('appointment_id', appointment_id, 'from', me.name, 'by', 'agency'));
    INSERT INTO core.owner_invite (agency_account_id, email, message, invited_by_user_id, status, appointment_id, closed_at, notify_owner)
    VALUES (me.id, v_email, v_msg, v_user, 'converted', appointment_id, now(), v_notify) RETURNING id INTO invite_id;
    outcome := 'request';
  ELSE
    INSERT INTO core.owner_invite (agency_account_id, email, message, invited_by_user_id, notify_owner)
    VALUES (me.id, v_email, v_msg, v_user, v_notify) RETURNING id INTO invite_id;
    outcome := 'invited';
    IF o.id IS NOT NULL AND core.fn_invite_verifies(o.id) THEN
      SELECT * INTO v FROM core.owner_invite WHERE id = invite_id;
      IF v.status = 'converted' AND v.appointment_id IS NOT NULL THEN outcome := 'request'; appointment_id := v.appointment_id; END IF;
    END IF;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_owner_invite(citext, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_owner_invite(citext, text, boolean) TO meesam_app;

COMMIT;
