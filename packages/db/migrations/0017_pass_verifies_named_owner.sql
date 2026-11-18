-- 0017 — An owner named on a pass needs no staff review (Founder ruling 18 Nov 2026).
-- When an agency issues a pass and has it e-mailed to the owner, that verified agency is vouching for the
-- person at that address. An owner account created with the same e-mail address (address confirmed, waiting
-- for review) is verified by redeeming the pass; there is nothing further for staff to check. A pass handed
-- over as a bare code, or opened from another address, still needs a verified owner account.
BEGIN;

ALTER TYPE core.verification_method ADD VALUE IF NOT EXISTS 'owner_pass';

-- Who a valid pass is addressed to, seen from one e-mail address: 'named' (the agency had it sent to this
-- address), 'open' (no address was given), 'other' (sent to a different address); NULL for an invalid code.
CREATE FUNCTION core.fn_pass_addressee(p_code text, p_email citext) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT CASE WHEN p.sent_to IS NULL THEN 'open' WHEN p.sent_to = p_email THEN 'named' ELSE 'other' END
    FROM core.owner_pass p
   WHERE p.token_hash = digest(core.fn_pass_normalise(p_code), 'sha256') AND p.redeemed_at IS NULL AND p.expires_at > now()
$$;
REVOKE EXECUTE ON FUNCTION core.fn_pass_addressee(text, citext) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_pass_addressee(text, citext) TO meesam_app;

-- Redemption as in 0015, except for the verification rule above.
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
