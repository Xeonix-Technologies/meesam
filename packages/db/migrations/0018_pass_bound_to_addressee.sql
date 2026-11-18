-- 0018 — A pass sent to an address is attached only by that address (Founder ruling 18 Nov 2026).
-- When the agency has a pass e-mailed to the owner, only a user signed in with that same e-mail address can
-- redeem it; another account that opens the link is refused. A pass issued without an address stays a bare
-- code that any verified owner account holding it can redeem. (A pass meant for one address was attached by
-- another account that was signed in in the same browser; the warning alone did not prevent it.)
BEGIN;

-- Redemption as in 0017, with the address rule added.
CREATE OR REPLACE FUNCTION core.fn_pass_redeem(p_code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'core', 'platform', 'public', 'pg_temp'
AS $fn$
DECLARE me uuid := platform.current_account_id(); u core.app_user; a core.account; p core.owner_pass; f core.mark_family; v_family uuid; v_app uuid;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me;
  SELECT * INTO a FROM core.account WHERE id = me;
  IF u.id IS NULL OR u.status <> 'active' OR a.kind NOT IN ('owner_individual', 'owner_company') THEN
    RAISE EXCEPTION 'a pass is redeemed by an owner account' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO p FROM core.owner_pass WHERE token_hash = digest(core.fn_pass_normalise(p_code), 'sha256') FOR UPDATE;
  -- 0018: a pass the agency sent to an address is for that address only
  IF p.id IS NOT NULL AND p.sent_to IS NOT NULL AND p.sent_to <> u.email THEN
    RAISE EXCEPTION 'pass was sent to another address' USING ERRCODE = '42501';
  END IF;
  -- 0017: an owner account still waiting for review is verified here, but only by a pass the agency had sent
  -- to this user's own e-mail address; any other pass needs an account already verified
  IF a.verified_at IS NULL THEN
    IF p.id IS NOT NULL AND p.redeemed_at IS NULL AND p.expires_at >= now() AND p.sent_to = u.email AND a.verification_status = 'pending_review' THEN
      UPDATE core.account SET verification_status = 'verified', verified_at = now(), verification_method = 'owner_pass',
             review_note = 'Verified by owner pass issued by account ' || p.issued_by_account_id::text WHERE id = me;
    ELSE
      RAISE EXCEPTION 'a pass is redeemed by a verified owner account' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF p.id IS NULL OR p.redeemed_at IS NOT NULL OR p.expires_at < now() THEN
    RAISE EXCEPTION 'pass is invalid, used or expired' USING ERRCODE = '22023';
  END IF;
  SELECT fam.* INTO f FROM core.record r JOIN core.mark_family fam ON fam.id = r.mark_family_id WHERE r.id = p.record_id FOR UPDATE OF fam;
  IF f.owner_account_id <> p.issued_by_account_id THEN
    RAISE EXCEPTION 'pass is invalid, used or expired' USING ERRCODE = '22023';      -- the record has moved since the pass was issued
  END IF;

  IF (SELECT count(*) FROM core.record WHERE mark_family_id = f.id) > 1 THEN
    INSERT INTO core.mark_family (owner_account_id, name, mark_type) VALUES (me, f.name, f.mark_type) RETURNING id INTO v_family;
    UPDATE core.record SET mark_family_id = v_family WHERE id = p.record_id;
  ELSE
    UPDATE core.mark_family SET owner_account_id = me WHERE id = f.id;
  END IF;
  UPDATE core.owner_pass SET redeemed_at = now(), redeemed_by_account_id = me WHERE id = p.id;

  -- the agency that entered the record keeps managing it: an appointment in force with this record in scope
  SELECT id INTO v_app FROM core.appointment WHERE owner_account_id = me AND agency_account_id = p.issued_by_account_id AND status IN ('requested', 'accepted') FOR UPDATE;
  IF v_app IS NULL THEN
    INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by, accepted_at)
    VALUES (me, p.issued_by_account_id, 'accepted', 'agency', now()) RETURNING id INTO v_app;
  ELSE
    UPDATE core.appointment SET status = 'accepted', accepted_at = COALESCE(accepted_at, now()) WHERE id = v_app;
  END IF;
  INSERT INTO core.appointment_record (appointment_id, record_id)
  SELECT v_app, p.record_id WHERE NOT EXISTS (SELECT 1 FROM core.appointment_record WHERE appointment_id = v_app AND record_id = p.record_id AND removed_at IS NULL);

  INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
  VALUES (p.issued_by_account_id, 'in_app', 'pass_redeemed', p.record_id, jsonb_build_object('by_account', me));
  RETURN p.record_id;
END $fn$
;

COMMIT;
