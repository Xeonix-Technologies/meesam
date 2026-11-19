-- 0032 — Cross-border instruction, two further points of System Description 4.4 link 3 / item 26:
--  (a) the instruction carries the owner's legal request and the power of attorney: the sender attaches up to two
--      documents of the record (columns legal_request_doc_id, poa_doc_id, present since 0001). The instructed
--      office can open those two documents while the instruction waits for its answer or is in force; the rest
--      of the record's documents open only once it has accepted.
--  (b) "name the correspondent to the owner": a switch on an instruction sent by an agency. Off by default
--      (the owner reads "handled through [agency]"); on, the owner is shown the instructed office by name.
BEGIN;

ALTER TABLE core.cross_border_instruction ADD COLUMN named_to_owner boolean NOT NULL DEFAULT false;

-- (a) the sender names the two documents when instructing
DROP FUNCTION core.fn_instruction_request(uuid, uuid, citext, text);
CREATE FUNCTION core.fn_instruction_request(p_record_id uuid, p_to uuid DEFAULT NULL, p_to_email citext DEFAULT NULL, p_message text DEFAULT NULL,
                                            p_legal_doc uuid DEFAULT NULL, p_poa_doc uuid DEFAULT NULL) RETURNS uuid
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
  IF (p_legal_doc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.document d WHERE d.id = p_legal_doc AND d.record_id = p_record_id))
     OR (p_poa_doc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.document d WHERE d.id = p_poa_doc AND d.record_id = p_record_id)) THEN
    RAISE EXCEPTION 'an attached document must belong to the record' USING ERRCODE = '22023';
  END IF;
  INSERT INTO core.cross_border_instruction (from_account_id, to_account_id, record_id, status, message, requested_by_user_id, legal_request_doc_id, poa_doc_id)
  VALUES (me.id, o.id, p_record_id, 'requested', NULLIF(left(btrim(COALESCE(p_message, '')), 1000), ''), platform.current_user_id(), p_legal_doc, p_poa_doc)
  RETURNING id INTO v_id;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (o.id, 'in_app', 'instruction_requested', jsonb_build_object('instruction_id', v_id, 'from', me.name));
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_instruction_request(uuid, uuid, citext, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_instruction_request(uuid, uuid, citext, text, uuid, uuid) TO meesam_app;

-- one of the two attached documents, for a party to the instruction while it is open (the sender: always)
CREATE FUNCTION core.fn_instruction_doc(p_instruction_id uuid, p_which text, OUT object_key text, OUT file_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); i core.cross_border_instruction; v_doc uuid;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id;
  IF i.id IS NULL OR me IS NULL OR NOT (me = i.from_account_id OR (me = i.to_account_id AND i.status IN ('requested', 'active'))) THEN
    RAISE EXCEPTION 'not a party to this instruction' USING ERRCODE = '42501';
  END IF;
  v_doc := CASE p_which WHEN 'legal' THEN i.legal_request_doc_id WHEN 'poa' THEN i.poa_doc_id END;
  SELECT d.object_key, d.file_name INTO object_key, file_name FROM core.document d WHERE d.id = v_doc AND d.record_id = i.record_id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_instruction_doc(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_instruction_doc(uuid, text) TO meesam_app;

-- (b) the instructing agency names, or stops naming, the instructed office to the owner
CREATE FUNCTION core.fn_instruction_name_to_owner(p_instruction_id uuid, p_named boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_agency_actor(false); i core.cross_border_instruction;
BEGIN
  SELECT * INTO i FROM core.cross_border_instruction WHERE id = p_instruction_id FOR UPDATE;
  IF i.id IS NULL OR i.from_account_id <> me.id THEN RAISE EXCEPTION 'only the instructing office decides this' USING ERRCODE = '42501'; END IF;
  IF i.status NOT IN ('requested', 'active') THEN RAISE EXCEPTION 'the instruction is already closed' USING ERRCODE = '22023'; END IF;
  UPDATE core.cross_border_instruction SET named_to_owner = COALESCE(p_named, false) WHERE id = i.id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_instruction_name_to_owner(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_instruction_name_to_owner(uuid, boolean) TO meesam_app;

-- who made a change, as the reader may be told: now honouring the switch for the owner
CREATE OR REPLACE FUNCTION core.fn_record_actor(p_record_id uuid, p_account_id uuid, OUT name jsonb, OUT through jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); v_owner uuid;
BEGIN
  IF p_account_id IS NULL OR me IS NULL OR NOT core.fn_can_access(p_record_id, me) THEN RETURN; END IF;
  SELECT f.owner_account_id INTO v_owner FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id;
  IF p_account_id = me OR p_account_id = v_owner OR core.fn_is_counterparty(p_account_id, me)
     OR (me = v_owner AND EXISTS (SELECT 1 FROM core.cross_border_instruction i
                                   WHERE i.record_id = p_record_id AND i.to_account_id = p_account_id AND i.named_to_owner)) THEN
    SELECT a.name INTO name FROM core.account a WHERE a.id = p_account_id;
    RETURN;
  END IF;
  SELECT a.name INTO through FROM core.cross_border_instruction i JOIN core.account a ON a.id = i.from_account_id
   WHERE i.record_id = p_record_id AND i.to_account_id = p_account_id AND i.status IN ('active', 'ended')
     AND (i.from_account_id = v_owner OR core.fn_is_counterparty(i.from_account_id, me))
   ORDER BY i.created_at DESC LIMIT 1;
END $$;

-- for the owner: the offices its agencies named to it on this record, while the instruction is in force
CREATE FUNCTION core.fn_record_named_offices(p_record_id uuid) RETURNS TABLE (office jsonb, country text, through jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT o.name, o.country::text, g.name
    FROM core.cross_border_instruction i JOIN core.account o ON o.id = i.to_account_id JOIN core.account g ON g.id = i.from_account_id
    JOIN core.record r ON r.id = i.record_id JOIN core.mark_family f ON f.id = r.mark_family_id
   WHERE i.record_id = p_record_id AND i.named_to_owner AND i.status = 'active'
     AND f.owner_account_id = platform.current_account_id() AND i.from_account_id <> f.owner_account_id
     AND core.fn_holds_record(i.record_id, i.from_account_id)
$$;
REVOKE EXECUTE ON FUNCTION core.fn_record_named_offices(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_record_named_offices(uuid) TO meesam_app;

-- the list, now with the attached documents and the switch
DROP FUNCTION core.fn_instruction_list(uuid);
CREATE FUNCTION core.fn_instruction_list(p_record_id uuid DEFAULT NULL)
RETURNS TABLE (id uuid, status core.instruction_status, direction text, record_id uuid, mark_text jsonb, registry_code text, number text,
               other_account_id uuid, other_name jsonb, other_country text, owner_name jsonb, message text, decline_note text,
               created_at timestamptz, accepted_at timestamptz, ended_at timestamptz, in_force boolean,
               legal_doc_name text, poa_doc_name text, named_to_owner boolean, from_is_owner boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
  SELECT i.id, i.status, CASE WHEN i.from_account_id = platform.current_account_id() THEN 'sent' ELSE 'received' END,
         i.record_id, r.mark_text, g.code::text, COALESCE(r.registration_no, r.application_no),
         o.id, o.name, o.country::text,
         CASE WHEN f.owner_account_id <> i.from_account_id THEN w.name END,
         i.message, i.decline_note, i.created_at, i.accepted_at, i.ended_at,
         i.status = 'active' AND core.fn_holds_record(i.record_id, i.from_account_id),
         (SELECT d.file_name FROM core.document d WHERE d.id = i.legal_request_doc_id),
         (SELECT d.file_name FROM core.document d WHERE d.id = i.poa_doc_id),
         i.named_to_owner, f.owner_account_id = i.from_account_id
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
REVOKE EXECUTE ON FUNCTION core.fn_instruction_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_instruction_list(uuid) TO meesam_app;

COMMIT;
