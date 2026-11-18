-- 0026 — An agency invites an owner by e-mail (Founder ruling 18 Nov 2026, point 10).
-- The agency enters the owner's e-mail address. If a verified owner account already has a user with that
-- address, the owner receives an appointment request at once (requested_by = agency; the owner chooses the
-- trademarks on acceptance, as in 0010). Otherwise the invitation waits, the address receives a sign-up link,
-- and the invitation turns into the same appointment request when an owner account with that address is verified.
-- The app role only reads its own office's invitations; every change goes through the functions below.
BEGIN;

CREATE TABLE core.owner_invite (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_account_id  uuid NOT NULL REFERENCES core.account(id),
  email              citext NOT NULL,
  message            text NULL,
  invited_by_user_id uuid NULL REFERENCES core.app_user(id),
  status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'converted', 'withdrawn')),
  appointment_id     uuid NULL REFERENCES core.appointment(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  closed_at          timestamptz NULL
);
CREATE UNIQUE INDEX owner_invite_one_pending ON core.owner_invite (agency_account_id, email) WHERE status = 'pending';
CREATE INDEX ON core.owner_invite (email) WHERE status = 'pending';
ALTER TABLE core.owner_invite ENABLE ROW LEVEL SECURITY;
CREATE POLICY owner_invite_select ON core.owner_invite FOR SELECT TO meesam_app USING (agency_account_id = platform.current_account_id());
GRANT SELECT ON core.owner_invite TO meesam_app;

-- Turns the waiting invitations addressed to an account's active users into appointment requests.
-- Runs for a verified owner account only; an open request or appointment with the same agency absorbs the invitation.
CREATE FUNCTION core.fn_owner_invites_convert(p_account_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a core.account; i core.owner_invite; g core.account; v_id uuid; n integer := 0;
BEGIN
  SELECT * INTO a FROM core.account WHERE id = p_account_id;
  IF a.id IS NULL OR a.verified_at IS NULL OR a.kind = 'agency_office' OR a.is_staff THEN RETURN 0; END IF;
  FOR i IN SELECT v.* FROM core.owner_invite v
            WHERE v.status = 'pending'
              AND v.email IN (SELECT u.email FROM core.app_user u WHERE u.account_id = a.id AND u.status = 'active')
            ORDER BY v.created_at FOR UPDATE OF v LOOP
    SELECT * INTO g FROM core.account WHERE id = i.agency_account_id;
    SELECT id INTO v_id FROM core.appointment
     WHERE owner_account_id = a.id AND agency_account_id = g.id AND status IN ('requested', 'accepted');
    IF v_id IS NULL AND g.verified_at IS NOT NULL THEN
      INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, message)
      VALUES (a.id, g.id, 'requested', 'agency', i.message) RETURNING id INTO v_id;
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (a.id, 'in_app', 'appointment_requested', jsonb_build_object('appointment_id', v_id, 'from', g.name, 'by', 'agency'));
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (g.id, 'in_app', 'owner_invite_joined', jsonb_build_object('appointment_id', v_id, 'email', i.email::text));
    END IF;
    UPDATE core.owner_invite SET status = 'converted', appointment_id = v_id, closed_at = now() WHERE id = i.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_owner_invites_convert(uuid) FROM PUBLIC, meesam_app;

CREATE FUNCTION core.trg_owner_invites_account() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN PERFORM core.fn_owner_invites_convert(NEW.id); RETURN NULL; END $$;
CREATE TRIGGER account_owner_invites AFTER UPDATE OF verified_at ON core.account
  FOR EACH ROW WHEN (OLD.verified_at IS NULL AND NEW.verified_at IS NOT NULL) EXECUTE FUNCTION core.trg_owner_invites_account();

CREATE FUNCTION core.trg_owner_invites_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF NEW.status = 'active' THEN PERFORM core.fn_owner_invites_convert(NEW.account_id); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER app_user_owner_invites AFTER INSERT OR UPDATE OF status, email ON core.app_user
  FOR EACH ROW EXECUTE FUNCTION core.trg_owner_invites_user();

-- The agency's entry point. Returns what happened: 'request' (an existing owner was asked; the appointment id
-- is returned so the owner's users can be told by e-mail) or 'invited' (the address gets a sign-up link).
CREATE FUNCTION core.fn_owner_invite(p_email citext, p_message text DEFAULT NULL, OUT outcome text, OUT appointment_id uuid, OUT invite_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); v_user uuid := platform.current_user_id(); v_email citext := btrim(p_email::text)::citext;
        o core.account; v_msg text := NULLIF(left(btrim(COALESCE(p_message, '')), 1000), '');
BEGIN
  IF me.kind <> 'agency_office' THEN RAISE EXCEPTION 'only an agency office invites an owner' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.app_user WHERE id = v_user AND account_id = me.id AND status = 'active' AND role IN ('agency_admin', 'agent')) THEN
    RAISE EXCEPTION 'only the administrator or an agent invites an owner' USING ERRCODE = '42501';
  END IF;
  IF v_email::text !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email::text) > 254 THEN RAISE EXCEPTION 'not an e-mail address' USING ERRCODE = '22023'; END IF;
  -- RULING NEEDED: is there a limit on invitations an office may send? 50 in 24 hours is taken, against use of the feature for bulk mail.
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
    INSERT INTO core.owner_invite (agency_account_id, email, message, invited_by_user_id, status, appointment_id, closed_at)
    VALUES (me.id, v_email, v_msg, v_user, 'converted', appointment_id, now()) RETURNING id INTO invite_id;
    outcome := 'request';
  ELSE
    INSERT INTO core.owner_invite (agency_account_id, email, message, invited_by_user_id)
    VALUES (me.id, v_email, v_msg, v_user) RETURNING id INTO invite_id;
    outcome := 'invited';
  END IF;
END $$;

-- The agency withdraws an invitation that is still waiting.
CREATE FUNCTION core.fn_owner_invite_withdraw(p_invite_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me();
BEGIN
  UPDATE core.owner_invite SET status = 'withdrawn', closed_at = now()
   WHERE id = p_invite_id AND agency_account_id = me.id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'no waiting invitation' USING ERRCODE = '22023'; END IF;
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_owner_invite(citext, text), core.fn_owner_invite_withdraw(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_owner_invite(citext, text), core.fn_owner_invite_withdraw(uuid) TO meesam_app;

COMMIT;
