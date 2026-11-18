-- 0027 — Cross-border instruction (System Description 4.4 link 3; items 6, 23, 26, 38; Data Architecture: agency
-- office → another agency office on a record) with a closed write path, and the instructed office's edit right
-- (Founder ruling 18 Nov 2026, point 17: the instructed office may edit the record for updates in its country;
-- a record is one registry's record, so the right is the edit right on the record it was instructed on).
--
-- Security correction. The 0001 policy let the app role write instruction rows directly, with any status.
-- From here the app role only reads the instructions it sent or received; every change goes through the
-- functions below:  requested -> active | declined,  requested | active -> ended.
-- Visibility (item 26): the owner is not shown the instructed office; the two offices see each other, and the
-- instructed office sees the owner of the record it works on.
BEGIN;

ALTER TABLE core.cross_border_instruction ADD COLUMN IF NOT EXISTS message text NULL;
ALTER TABLE core.cross_border_instruction ADD COLUMN IF NOT EXISTS decline_note text NULL;
ALTER TABLE core.cross_border_instruction ADD COLUMN IF NOT EXISTS requested_by_user_id uuid NULL REFERENCES core.app_user(id);
ALTER TABLE core.cross_border_instruction ADD COLUMN IF NOT EXISTS accepted_at timestamptz NULL;
ALTER TABLE core.cross_border_instruction ADD COLUMN IF NOT EXISTS ended_by_account_id uuid NULL REFERENCES core.account(id);
CREATE UNIQUE INDEX instruction_one_open ON core.cross_border_instruction (record_id, to_account_id) WHERE status IN ('requested', 'active');

DROP POLICY IF EXISTS cbi_all ON core.cross_border_instruction;
CREATE POLICY cbi_select ON core.cross_border_instruction FOR SELECT TO meesam_app
  USING (from_account_id = platform.current_account_id() OR to_account_id = platform.current_account_id());
REVOKE INSERT, UPDATE, DELETE ON core.cross_border_instruction FROM meesam_app;

-- Does an agency hold a record in its own right: as the account the family sits in, or under an accepted appointment?
CREATE FUNCTION core.fn_holds_record(p_record_id uuid, p_account_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id AND f.owner_account_id = p_account_id)
      OR EXISTS (SELECT 1 FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
                  WHERE ar.record_id = p_record_id AND a.agency_account_id = p_account_id AND a.status = 'accepted' AND a.ended_at IS NULL)
$$;
REVOKE EXECUTE ON FUNCTION core.fn_holds_record(uuid, uuid) FROM PUBLIC, meesam_app;
-- the same question for the calling account only
CREATE FUNCTION core.fn_i_hold_record(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT core.fn_holds_record(p_record_id, platform.current_account_id())
$$;
REVOKE EXECUTE ON FUNCTION core.fn_i_hold_record(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_i_hold_record(uuid) TO meesam_app;

-- Access: an active instruction gives the instructed office the record, with edit (ruling 17), for as long as
-- the instructing office itself still holds the record. When the instructing office's appointment ends, the
-- instructed office's access ends with it (item 38: no access after an appointment ends).
CREATE OR REPLACE VIEW core.v_record_access (record_id, account_id, via, can_edit) AS
  SELECT r.id, f.owner_account_id, 'owner'::text, true
    FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id
  UNION ALL
  SELECT ar.record_id, a.agency_account_id, 'appointment', true
    FROM core.appointment a
    JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
   WHERE a.status = 'accepted' AND a.ended_at IS NULL
  UNION ALL
  SELECT i.record_id, i.to_account_id, 'cross_border', true
    FROM core.cross_border_instruction i
   WHERE i.status = 'active' AND core.fn_holds_record(i.record_id, i.from_account_id);

-- Security correction. The access view runs with its owner's rights, so the app role could read from it which
-- accounts reach which records across all tenants (identifiers only). The app asks fn_can_access instead.
REVOKE SELECT ON core.v_record_access FROM meesam_app;

-- Whose account name may be read: as before, plus the two offices of an instruction (either way), and the
-- owner of the record for the office instructed on it. The owner is NOT given the instructed office (item 26).
CREATE OR REPLACE FUNCTION core.fn_is_counterparty(p_other uuid, p_me uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM core.appointment a
                  WHERE (a.owner_account_id = p_me AND a.agency_account_id = p_other) OR (a.agency_account_id = p_me AND a.owner_account_id = p_other))
      OR EXISTS (SELECT 1 FROM core.quote_request_recipient r JOIN core.quote_request q ON q.id = r.quote_request_id
                  WHERE (q.owner_account_id = p_me AND r.agency_account_id = p_other) OR (r.agency_account_id = p_me AND q.owner_account_id = p_other))
      OR EXISTS (SELECT 1 FROM core.cross_border_instruction i
                  WHERE (i.from_account_id = p_me AND i.to_account_id = p_other) OR (i.to_account_id = p_me AND i.from_account_id = p_other))
      OR EXISTS (SELECT 1 FROM core.cross_border_instruction i JOIN core.record r ON r.id = i.record_id JOIN core.mark_family f ON f.id = r.mark_family_id
                  WHERE i.to_account_id = p_me AND i.status = 'active' AND f.owner_account_id = p_other)
$$;

-- Who made a change, as the reader may be told. Returns the account's name where the reader may know it;
-- for a change made by an instructed office that the reader is not shown (the owner), returns the instructing
-- office in "through" instead: the record is "handled through [instructing agency]" (item 26).
CREATE FUNCTION core.fn_record_actor(p_record_id uuid, p_account_id uuid, OUT name jsonb, OUT through jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); v_owner uuid;
BEGIN
  IF p_account_id IS NULL OR me IS NULL OR NOT core.fn_can_access(p_record_id, me) THEN RETURN; END IF;
  SELECT f.owner_account_id INTO v_owner FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id;
  IF p_account_id = me OR p_account_id = v_owner OR core.fn_is_counterparty(p_account_id, me) THEN
    SELECT a.name INTO name FROM core.account a WHERE a.id = p_account_id;
    RETURN;
  END IF;
  SELECT a.name INTO through FROM core.cross_border_instruction i JOIN core.account a ON a.id = i.from_account_id
   WHERE i.record_id = p_record_id AND i.to_account_id = p_account_id AND i.status IN ('active', 'ended')
     AND (i.from_account_id = v_owner OR core.fn_is_counterparty(i.from_account_id, me))
   ORDER BY i.created_at DESC LIMIT 1;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_record_actor(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_record_actor(uuid, uuid) TO meesam_app;

-- the acting agency user: active, of a verified agency office
CREATE FUNCTION core.fn_agency_actor(p_admin_only boolean DEFAULT false) RETURNS core.account
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); u core.app_user;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me.id;
  IF me.kind <> 'agency_office' OR u.id IS NULL OR u.status <> 'active'
     OR NOT (u.role = 'agency_admin' OR (NOT p_admin_only AND u.role = 'agent')) THEN
    RAISE EXCEPTION 'not allowed for this user' USING ERRCODE = '42501';
  END IF;
  RETURN me;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_agency_actor(boolean) FROM PUBLIC, meesam_app;

-- An agency office holding a record instructs another agency office on it. The other office is named by its
-- account (from the directory) or by the e-mail address of one of its users (a sister office that is not listed).
CREATE FUNCTION core.fn_instruction_request(p_record_id uuid, p_to uuid DEFAULT NULL, p_to_email citext DEFAULT NULL, p_message text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_agency_actor(); o core.account; v_id uuid;
BEGIN
  IF NOT core.fn_holds_record(p_record_id, me.id) THEN
    RAISE EXCEPTION 'only an office holding the record instructs another office on it' USING ERRCODE = '42501';
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

-- The instructed office accepts or declines.
-- RULING NEEDED: the documents give accepting or declining a cross-border instruction to the Administrator; the
-- ruling of 18 Nov that an Agent may answer requests was made for appointment requests. Administrator only is taken.
CREATE FUNCTION core.fn_instruction_respond(p_instruction_id uuid, p_accept boolean, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_agency_actor(true); i core.cross_border_instruction;
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

-- Either office ends an instruction in force, or the sender withdraws one still waiting. Access ends at once.
CREATE FUNCTION core.fn_instruction_end(p_instruction_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_agency_actor(true); i core.cross_border_instruction;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id FOR UPDATE;
  IF i.id IS NULL OR me.id NOT IN (i.from_account_id, i.to_account_id) THEN RAISE EXCEPTION 'not a party to this instruction' USING ERRCODE = '42501'; END IF;
  IF i.status NOT IN ('requested', 'active') THEN RAISE EXCEPTION 'the instruction is already closed' USING ERRCODE = '22023'; END IF;
  UPDATE core.cross_border_instruction SET status = 'ended', ended_at = now(), ended_by_account_id = me.id WHERE id = i.id;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (CASE WHEN me.id = i.from_account_id THEN i.to_account_id ELSE i.from_account_id END, 'in_app', 'instruction_ended',
          jsonb_build_object('instruction_id', i.id, 'from', me.name));
END $$;

-- The caller's instructions, sent and received, with what each side may know. Before accepting, the instructed
-- office is told the mark, the registry and the owner (the instruction carries the owner's request), not the record.
CREATE FUNCTION core.fn_instruction_list(p_record_id uuid DEFAULT NULL)
RETURNS TABLE (id uuid, status core.instruction_status, direction text, record_id uuid, mark_text jsonb, registry_code text, number text,
               other_account_id uuid, other_name jsonb, other_country text, owner_name jsonb, message text, decline_note text,
               created_at timestamptz, accepted_at timestamptz, ended_at timestamptz, in_force boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
  SELECT i.id, i.status, CASE WHEN i.from_account_id = platform.current_account_id() THEN 'sent' ELSE 'received' END,
         i.record_id, r.mark_text, g.code::text, COALESCE(r.registration_no, r.application_no),
         o.id, o.name, o.country::text,
         CASE WHEN f.owner_account_id <> i.from_account_id THEN w.name END,
         i.message, i.decline_note, i.created_at, i.accepted_at, i.ended_at,
         i.status = 'active' AND core.fn_holds_record(i.record_id, i.from_account_id)
    FROM core.cross_border_instruction i
    JOIN core.record r ON r.id = i.record_id
    JOIN core.mark_family f ON f.id = r.mark_family_id
    JOIN core.account w ON w.id = f.owner_account_id
    JOIN registry.registry g ON g.id = r.registry_id
    JOIN core.account o ON o.id = CASE WHEN i.from_account_id = platform.current_account_id() THEN i.to_account_id ELSE i.from_account_id END
   WHERE platform.current_account_id() IN (i.from_account_id, i.to_account_id)
     AND (p_record_id IS NULL OR i.record_id = p_record_id)
   ORDER BY (i.status = 'requested') DESC, (i.status = 'active') DESC, i.created_at DESC
$$;

-- The other office's users who are told by e-mail (active administrators and agents).
CREATE FUNCTION core.fn_instruction_recipients(p_instruction_id uuid)
RETURNS TABLE (email citext, name text, locale text, account_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); i core.cross_border_instruction; v_other uuid;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id;
  IF i.id IS NULL OR me IS NULL OR me NOT IN (i.from_account_id, i.to_account_id) THEN RAISE EXCEPTION 'not a party to this instruction' USING ERRCODE = '42501'; END IF;
  v_other := CASE WHEN me = i.from_account_id THEN i.to_account_id ELSE i.from_account_id END;
  RETURN QUERY SELECT u.email, u.name, u.locale, u.account_id FROM core.app_user u
                WHERE u.account_id = v_other AND u.status = 'active' AND u.role IN ('agency_admin', 'agent');
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_instruction_request(uuid, uuid, citext, text), core.fn_instruction_respond(uuid, boolean, text),
  core.fn_instruction_end(uuid), core.fn_instruction_list(uuid), core.fn_instruction_recipients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_instruction_request(uuid, uuid, citext, text), core.fn_instruction_respond(uuid, boolean, text),
  core.fn_instruction_end(uuid), core.fn_instruction_list(uuid), core.fn_instruction_recipients(uuid) TO meesam_app;

COMMIT;
