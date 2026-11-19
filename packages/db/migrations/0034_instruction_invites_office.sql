-- 0034 — Instructing an agency office that is not on Meesam yet (System Description 4.4 link 3: "invite a
-- correspondent"). The sender gives the office's e-mail address. If an active user of a verified agency office
-- has it, the instruction is sent at once (0027/0029). Otherwise the instruction waits as an invitation, the
-- address gets a link to create an agency account, and the invitation becomes the instruction when an agency
-- office with that address is verified (agency offices are verified by staff). The sender can withdraw it.
-- The app role only reads the invitations of its own account; every change goes through the functions below.
BEGIN;

CREATE TABLE core.instruction_invite (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_account_id      uuid NOT NULL REFERENCES core.account(id),
  record_id            uuid NOT NULL REFERENCES core.record(id),
  email                citext NOT NULL,
  message              text NULL,
  legal_request_doc_id uuid NULL REFERENCES core.document(id),
  poa_doc_id           uuid NULL REFERENCES core.document(id),
  invited_by_user_id   uuid NULL REFERENCES core.app_user(id),
  status               text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'converted', 'withdrawn', 'lapsed')),
  instruction_id       uuid NULL REFERENCES core.cross_border_instruction(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  closed_at            timestamptz NULL
);
CREATE UNIQUE INDEX instruction_invite_one_pending ON core.instruction_invite (from_account_id, record_id, email) WHERE status = 'pending';
CREATE INDEX ON core.instruction_invite (email) WHERE status = 'pending';
ALTER TABLE core.instruction_invite ENABLE ROW LEVEL SECURITY;
CREATE POLICY instruction_invite_select ON core.instruction_invite FOR SELECT TO meesam_app USING (from_account_id = platform.current_account_id());
GRANT SELECT ON core.instruction_invite TO meesam_app;

-- Turns the waiting invitations addressed to a verified agency office's active users into instructions.
-- An invitation whose sender no longer holds the record lapses.
CREATE FUNCTION core.fn_instruction_invites_convert(p_account_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a core.account; v core.instruction_invite; s core.account; v_id uuid; n integer := 0;
BEGIN
  SELECT * INTO a FROM core.account WHERE id = p_account_id;
  IF a.id IS NULL OR a.verified_at IS NULL OR a.kind <> 'agency_office' OR a.is_staff THEN RETURN 0; END IF;
  FOR v IN SELECT i.* FROM core.instruction_invite i
            WHERE i.status = 'pending' AND i.from_account_id <> a.id
              AND i.email IN (SELECT u.email FROM core.app_user u WHERE u.account_id = a.id AND u.status = 'active')
            ORDER BY i.created_at FOR UPDATE OF i LOOP
    SELECT * INTO s FROM core.account WHERE id = v.from_account_id;
    IF NOT core.fn_holds_record(v.record_id, v.from_account_id) THEN
      UPDATE core.instruction_invite SET status = 'lapsed', closed_at = now() WHERE id = v.id;
      CONTINUE;
    END IF;
    SELECT id INTO v_id FROM core.cross_border_instruction
     WHERE record_id = v.record_id AND to_account_id = a.id AND status IN ('requested', 'active');
    IF v_id IS NULL THEN
      INSERT INTO core.cross_border_instruction (from_account_id, to_account_id, record_id, status, message, requested_by_user_id, legal_request_doc_id, poa_doc_id)
      VALUES (v.from_account_id, a.id, v.record_id, 'requested', v.message, v.invited_by_user_id, v.legal_request_doc_id, v.poa_doc_id)
      RETURNING id INTO v_id;
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (a.id, 'in_app', 'instruction_requested', jsonb_build_object('instruction_id', v_id, 'from', s.name));
      INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
      VALUES (s.id, 'in_app', 'instruction_invite_joined', v.record_id, jsonb_build_object('instruction_id', v_id, 'email', v.email::text));
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (a.id, 'email', 'instruction_invite_mail', jsonb_build_object('instruction_id', v_id, 'from', s.name, 'note', v.message));
    END IF;
    UPDATE core.instruction_invite SET status = 'converted', instruction_id = v_id, closed_at = now() WHERE id = v.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_instruction_invites_convert(uuid) FROM PUBLIC, meesam_app;

CREATE FUNCTION core.trg_instruction_invites_account() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN PERFORM core.fn_instruction_invites_convert(NEW.id); RETURN NULL; END $$;
CREATE TRIGGER account_instruction_invites AFTER UPDATE OF verified_at ON core.account
  FOR EACH ROW WHEN (OLD.verified_at IS NULL AND NEW.verified_at IS NOT NULL) EXECUTE FUNCTION core.trg_instruction_invites_account();

CREATE FUNCTION core.trg_instruction_invites_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF NEW.status = 'active' THEN PERFORM core.fn_instruction_invites_convert(NEW.account_id); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER app_user_instruction_invites AFTER INSERT OR UPDATE OF status, email ON core.app_user
  FOR EACH ROW EXECUTE FUNCTION core.trg_instruction_invites_user();

-- The sender names the office by e-mail. Returns 'request' (the office is on Meesam: instruction sent) or
-- 'invited' (not yet: the invitation waits and the web service sends the sign-up link).
CREATE FUNCTION core.fn_instruction_by_email(p_record_id uuid, p_email citext, p_message text DEFAULT NULL, p_legal_doc uuid DEFAULT NULL, p_poa_doc uuid DEFAULT NULL,
                                             OUT outcome text, OUT instruction_id uuid, OUT invite_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_instruction_actor(); v_email citext := btrim(p_email::text)::citext; o core.account;
BEGIN
  IF NOT core.fn_holds_record(p_record_id, me.id) THEN
    RAISE EXCEPTION 'only the owner or an office holding the record instructs an office on it' USING ERRCODE = '42501';
  END IF;
  IF v_email::text !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email::text) > 254 THEN RAISE EXCEPTION 'not an e-mail address' USING ERRCODE = '22023'; END IF;
  SELECT a.* INTO o FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.email = v_email AND u.status <> 'removed';
  IF o.id IS NOT NULL AND (o.kind <> 'agency_office' OR o.is_staff OR o.id = me.id) THEN
    RAISE EXCEPTION 'the other office is not available' USING ERRCODE = '22023';
  END IF;
  IF o.id IS NOT NULL AND o.verified_at IS NOT NULL AND EXISTS (SELECT 1 FROM core.app_user u WHERE u.email = v_email AND u.status = 'active') THEN
    instruction_id := core.fn_instruction_request(p_record_id, o.id, NULL, p_message, p_legal_doc, p_poa_doc);
    outcome := 'request';
    RETURN;
  END IF;
  IF (p_legal_doc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.document d WHERE d.id = p_legal_doc AND d.record_id = p_record_id))
     OR (p_poa_doc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.document d WHERE d.id = p_poa_doc AND d.record_id = p_record_id)) THEN
    RAISE EXCEPTION 'an attached document must belong to the record' USING ERRCODE = '22023';
  END IF;
  -- the same limit as invitations to owners (Founder ruling 19 Nov 2026): 50 per account in 24 hours, against bulk mail
  IF (SELECT count(*) FROM core.instruction_invite WHERE from_account_id = me.id AND created_at > now() - interval '24 hours') >= 50 THEN
    RAISE EXCEPTION 'invitation limit reached' USING ERRCODE = '54000';
  END IF;
  INSERT INTO core.instruction_invite (from_account_id, record_id, email, message, legal_request_doc_id, poa_doc_id, invited_by_user_id)
  VALUES (me.id, p_record_id, v_email, NULLIF(left(btrim(COALESCE(p_message, '')), 1000), ''), p_legal_doc, p_poa_doc, platform.current_user_id())
  RETURNING id INTO invite_id;
  outcome := 'invited';
END $$;

CREATE FUNCTION core.fn_instruction_invite_withdraw(p_invite_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_instruction_actor();
BEGIN
  UPDATE core.instruction_invite SET status = 'withdrawn', closed_at = now()
   WHERE id = p_invite_id AND from_account_id = me.id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'no waiting invitation' USING ERRCODE = '22023'; END IF;
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_instruction_by_email(uuid, citext, text, uuid, uuid), core.fn_instruction_invite_withdraw(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_instruction_by_email(uuid, citext, text, uuid, uuid), core.fn_instruction_invite_withdraw(uuid) TO meesam_app;

-- Hands the queued e-mails to the web service: the new office is told the instruction is waiting in its account.
CREATE FUNCTION platform.fn_instruction_invite_mails_take()
RETURNS TABLE (email citext, name text, locale text, account_id uuid, sender jsonb, mark_text jsonb, number text, registry_code text, note text)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, registry, public, pg_temp AS $$
  WITH taken AS (
    UPDATE platform.notification n SET status = 'sent', sent_at = now()
     WHERE n.channel = 'email' AND n.status = 'queued' AND n.kind = 'instruction_invite_mail'
    RETURNING n.account_id, n.payload)
  SELECT u.email, u.name, u.locale, u.account_id, t.payload -> 'from', r.mark_text, COALESCE(r.registration_no, r.application_no), g.code::text, t.payload ->> 'note'
    FROM taken t JOIN core.app_user u ON u.account_id = t.account_id
    JOIN core.cross_border_instruction i ON i.id = (t.payload ->> 'instruction_id')::uuid
    JOIN core.record r ON r.id = i.record_id JOIN registry.registry g ON g.id = r.registry_id
   WHERE u.status = 'active' AND u.role <> 'viewer'
$$;
REVOKE EXECUTE ON FUNCTION platform.fn_instruction_invite_mails_take() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_instruction_invite_mails_take() TO meesam_staff, meesam_admin;

COMMIT;
