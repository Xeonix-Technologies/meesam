-- 0028 — An agency's invitation verifies the invited owner (Founder ruling 19 Nov 2026).
-- An owner who confirms the e-mail address an agency invited needs no staff review: the agency vouched for the
-- address and the owner proved it is theirs. The account is verified at that moment (method 'agency_invite'),
-- the waiting invitation becomes the appointment request (0026), and the staff are told by e-mail.
-- This applies to owner accounts waiting for review only; a rejected account stays rejected.
BEGIN;

ALTER TYPE core.verification_method ADD VALUE IF NOT EXISTS 'agency_invite';

-- Verifies an owner account waiting for review when a verified agency has a waiting invitation for the address
-- of one of its active users. Queues the e-mail notice to the staff. Returns whether it verified.
CREATE FUNCTION core.fn_invite_verifies(p_account_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE a core.account; i core.owner_invite; g core.account; v_staff uuid;
BEGIN
  SELECT * INTO a FROM core.account WHERE id = p_account_id FOR UPDATE;
  IF a.id IS NULL OR a.verified_at IS NOT NULL OR a.verification_status <> 'pending_review' OR a.kind = 'agency_office' OR a.is_staff THEN RETURN false; END IF;
  SELECT v.* INTO i FROM core.owner_invite v JOIN core.account ag ON ag.id = v.agency_account_id
   WHERE v.status = 'pending' AND ag.verified_at IS NOT NULL
     AND v.email IN (SELECT u.email FROM core.app_user u WHERE u.account_id = a.id AND u.status = 'active')
   ORDER BY v.created_at LIMIT 1;
  IF i.id IS NULL THEN RETURN false; END IF;
  SELECT * INTO g FROM core.account WHERE id = i.agency_account_id;
  UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = 'agency_invite',
         review_note = 'Verified by invitation from agency account ' || g.id::text WHERE id = a.id;
  SELECT id INTO v_staff FROM core.account WHERE is_staff;
  IF v_staff IS NOT NULL THEN
    INSERT INTO platform.notification (account_id, channel, kind, payload)
    VALUES (v_staff, 'email', 'owner_verified_by_invite',
            jsonb_build_object('account_id', a.id, 'owner', a.name, 'kind', a.kind, 'email', i.email::text, 'agency', g.name));
  END IF;
  RETURN true;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_invite_verifies(uuid) FROM PUBLIC, meesam_app;

-- the moment an account's e-mail address is confirmed (it moves to review)
CREATE FUNCTION core.trg_invite_verifies() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
BEGIN PERFORM core.fn_invite_verifies(NEW.id); RETURN NULL; END $$;
CREATE TRIGGER account_invite_verifies AFTER UPDATE OF verification_status ON core.account
  FOR EACH ROW WHEN (NEW.verification_status = 'pending_review' AND OLD.verification_status IS DISTINCT FROM 'pending_review')
  EXECUTE FUNCTION core.trg_invite_verifies();

-- The agency's entry point (0026), now also covering an owner account that already waits for review:
-- the invitation verifies it at once and the request is sent.
CREATE OR REPLACE FUNCTION core.fn_owner_invite(p_email citext, p_message text DEFAULT NULL, OUT outcome text, OUT appointment_id uuid, OUT invite_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me core.account := core.fn_me(); v_user uuid := platform.current_user_id(); v_email citext := btrim(p_email::text)::citext;
        o core.account; v_msg text := NULLIF(left(btrim(COALESCE(p_message, '')), 1000), ''); v core.owner_invite;
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
    -- an owner account with this address that already waits for review is verified by the invitation (0028)
    IF o.id IS NOT NULL AND core.fn_invite_verifies(o.id) THEN
      SELECT * INTO v FROM core.owner_invite WHERE id = invite_id;
      IF v.status = 'converted' AND v.appointment_id IS NOT NULL THEN outcome := 'request'; appointment_id := v.appointment_id; END IF;
    END IF;
  END IF;
END $$;

-- Is the user's account verified? Read by the e-mail confirmation page to say what happens next.
CREATE FUNCTION core.fn_user_account_verified(p_user_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT COALESCE((SELECT a.verified_at IS NOT NULL FROM core.app_user u JOIN core.account a ON a.id = u.account_id WHERE u.id = p_user_id), false)
$$;
REVOKE EXECUTE ON FUNCTION core.fn_user_account_verified(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_user_account_verified(uuid) TO meesam_app;

-- Hands the queued staff notices to the web service for sending, one row per notice and System Administrator,
-- and marks them sent.
CREATE FUNCTION platform.fn_staff_notices_take() RETURNS TABLE (email citext, name text, locale text, kind text, payload jsonb)
LANGUAGE sql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
  WITH taken AS (
    UPDATE platform.notification n SET status = 'sent', sent_at = now()
     WHERE n.channel = 'email' AND n.status = 'queued' AND n.kind = 'owner_verified_by_invite'
       AND n.account_id = (SELECT id FROM core.account WHERE is_staff)
    RETURNING n.kind, n.payload)
  SELECT u.email, u.name, u.locale, t.kind, t.payload
    FROM taken t CROSS JOIN core.app_user u JOIN core.account a ON a.id = u.account_id AND a.is_staff
   WHERE u.status = 'active' AND EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = u.id AND s.role = 'system_admin')
$$;
REVOKE EXECUTE ON FUNCTION platform.fn_staff_notices_take() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_staff_notices_take() TO meesam_staff, meesam_admin;

COMMIT;
