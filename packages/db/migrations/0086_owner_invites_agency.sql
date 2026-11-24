-- 0086 — An owner invites an agency by e-mail (Founder ruling 24 Nov 2026), the mirror of 0026.
-- The owner enters the agent's e-mail address. If a verified agency office already has an active user with that
-- address, the office receives an appointment request at once (requested_by = owner; the owner names the trademarks
-- afterwards, on the appointment). Otherwise the invitation waits, the address receives a sign-up link, and the
-- invitation turns into the same appointment request when an agency office with that address is verified.
-- The app role only reads its own account's invitations; every change goes through the functions below.
BEGIN;

CREATE TABLE core.agency_invite (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id   uuid NOT NULL REFERENCES core.account(id),
  email              citext NOT NULL,
  message            text NULL,
  invited_by_user_id uuid NULL REFERENCES core.app_user(id),
  status             text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'converted', 'withdrawn')),
  appointment_id     uuid NULL REFERENCES core.appointment(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  closed_at          timestamptz NULL
);
CREATE UNIQUE INDEX agency_invite_one_pending ON core.agency_invite (owner_account_id, email) WHERE status = 'pending';
CREATE INDEX ON core.agency_invite (email) WHERE status = 'pending';
ALTER TABLE core.agency_invite ENABLE ROW LEVEL SECURITY;
CREATE POLICY agency_invite_select ON core.agency_invite FOR SELECT TO meesam_app USING (owner_account_id = platform.current_account_id());
GRANT SELECT ON core.agency_invite TO meesam_app;

-- Turns the waiting invitations addressed to an agency office's active users into appointment requests.
-- Runs for a verified agency office only; an open request or appointment with the same owner absorbs the invitation.
CREATE FUNCTION core.fn_agency_invites_convert(p_account_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a core.account; i core.agency_invite; o core.account; v_id uuid; n integer := 0;
BEGIN
  SELECT * INTO a FROM core.account WHERE id = p_account_id;
  IF a.id IS NULL OR a.verified_at IS NULL OR a.kind <> 'agency_office' OR a.is_staff THEN RETURN 0; END IF;
  FOR i IN SELECT v.* FROM core.agency_invite v
            WHERE v.status = 'pending'
              AND v.email IN (SELECT u.email FROM core.app_user u WHERE u.account_id = a.id AND u.status = 'active')
            ORDER BY v.created_at FOR UPDATE OF v LOOP
    SELECT * INTO o FROM core.account WHERE id = i.owner_account_id;
    v_id := NULL;
    SELECT id INTO v_id FROM core.appointment
     WHERE owner_account_id = o.id AND agency_account_id = a.id AND status IN ('requested', 'accepted');
    IF v_id IS NULL AND o.verified_at IS NOT NULL THEN
      INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, message)
      VALUES (o.id, a.id, 'requested', 'owner', i.message) RETURNING id INTO v_id;
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (a.id, 'in_app', 'appointment_requested', jsonb_build_object('appointment_id', v_id, 'from', o.name, 'by', 'owner'));
      INSERT INTO platform.notification (account_id, channel, kind, payload)
      VALUES (o.id, 'in_app', 'agency_invite_joined', jsonb_build_object('appointment_id', v_id, 'email', i.email::text));
    END IF;
    UPDATE core.agency_invite SET status = 'converted', appointment_id = v_id, closed_at = now() WHERE id = i.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_agency_invites_convert(uuid) FROM PUBLIC, meesam_app;

CREATE FUNCTION core.trg_agency_invites_account() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN PERFORM core.fn_agency_invites_convert(NEW.id); RETURN NULL; END $$;
CREATE TRIGGER account_agency_invites AFTER UPDATE OF verified_at ON core.account
  FOR EACH ROW WHEN (OLD.verified_at IS NULL AND NEW.verified_at IS NOT NULL) EXECUTE FUNCTION core.trg_agency_invites_account();

CREATE FUNCTION core.trg_agency_invites_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN
  IF NEW.status = 'active' THEN PERFORM core.fn_agency_invites_convert(NEW.account_id); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER app_user_agency_invites AFTER INSERT OR UPDATE OF status, email ON core.app_user
  FOR EACH ROW EXECUTE FUNCTION core.trg_agency_invites_user();

-- The owner's entry point. Returns what happened: 'request' (an existing agency office was asked; the appointment
-- id is returned so its users can be told by e-mail) or 'invited' (the address gets a sign-up link).
CREATE FUNCTION core.fn_agency_invite(p_email citext, p_message text DEFAULT NULL, OUT outcome text, OUT appointment_id uuid, OUT invite_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); v_user uuid := platform.current_user_id(); v_email citext := btrim(p_email::text)::citext;
        g core.account; v_msg text := NULLIF(left(btrim(COALESCE(p_message, '')), 1000), '');
BEGIN
  IF me.kind = 'agency_office' OR me.is_staff THEN RAISE EXCEPTION 'only an owner invites an agency' USING ERRCODE = '42501'; END IF;
  IF me.verified_at IS NULL THEN RAISE EXCEPTION 'the account is not verified' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.app_user WHERE id = v_user AND account_id = me.id AND status = 'active' AND role IN ('company_admin', 'tm_manager')) THEN
    RAISE EXCEPTION 'only the administrator or a trademark manager invites an agency' USING ERRCODE = '42501';
  END IF;
  IF v_email::text !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(v_email::text) > 254 THEN RAISE EXCEPTION 'not an e-mail address' USING ERRCODE = '22023'; END IF;
  -- the same limit as for an office inviting owners (0026), against use of the feature for bulk mail
  IF (SELECT count(*) FROM core.agency_invite WHERE owner_account_id = me.id AND created_at > now() - interval '24 hours') >= 50 THEN
    RAISE EXCEPTION 'invitation limit reached' USING ERRCODE = '54000';
  END IF;

  SELECT a.* INTO g FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.email = v_email AND u.status <> 'removed';
  IF g.id IS NOT NULL AND (g.kind <> 'agency_office' OR g.is_staff) THEN
    RAISE EXCEPTION 'the address does not belong to an agency' USING ERRCODE = '22023';
  END IF;

  IF g.id IS NOT NULL AND g.verified_at IS NOT NULL
     AND EXISTS (SELECT 1 FROM core.app_user u WHERE u.email = v_email AND u.status = 'active') THEN
    INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, message)
    VALUES (me.id, g.id, 'requested', 'owner', v_msg) RETURNING id INTO appointment_id;
    INSERT INTO platform.notification (account_id, channel, kind, payload)
    VALUES (g.id, 'in_app', 'appointment_requested', jsonb_build_object('appointment_id', appointment_id, 'from', me.name, 'by', 'owner'));
    INSERT INTO core.agency_invite (owner_account_id, email, message, invited_by_user_id, status, appointment_id, closed_at)
    VALUES (me.id, v_email, v_msg, v_user, 'converted', appointment_id, now()) RETURNING id INTO invite_id;
    outcome := 'request';
  ELSE
    INSERT INTO core.agency_invite (owner_account_id, email, message, invited_by_user_id)
    VALUES (me.id, v_email, v_msg, v_user) RETURNING id INTO invite_id;
    outcome := 'invited';
  END IF;
END $$;

-- The owner withdraws an invitation that is still waiting.
CREATE FUNCTION core.fn_agency_invite_withdraw(p_invite_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me();
BEGIN
  UPDATE core.agency_invite SET status = 'withdrawn', closed_at = now()
   WHERE id = p_invite_id AND owner_account_id = me.id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'no waiting invitation' USING ERRCODE = '22023'; END IF;
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_agency_invite(citext, text), core.fn_agency_invite_withdraw(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_agency_invite(citext, text), core.fn_agency_invite_withdraw(uuid) TO meesam_app;

COMMIT;
