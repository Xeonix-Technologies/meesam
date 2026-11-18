-- 0015 — Owner pass (System Description 4.4 link 2; items 11, 38, 39 (vii)).
-- An agency that created a record for a client issues a one-time code bound to that record; the owner
-- enters it and the record is attached to the owner's account. Single use, 30 days.
--
-- Closes the write path: the app role only reads its own passes; issuing and redeeming go through the
-- functions below (sp_redeem_pass of 0001 took any account id and is already revoked by 0010).
BEGIN;

DROP POLICY IF EXISTS owner_pass_insert ON core.owner_pass;
REVOKE INSERT, UPDATE, DELETE ON core.owner_pass FROM meesam_app;
ALTER TABLE core.owner_pass ADD COLUMN IF NOT EXISTS sent_to citext NULL;      -- where the agency had the code e-mailed, if it did

-- A code as typed: letters and digits only, upper case (dashes and spaces are for reading).
CREATE FUNCTION core.fn_pass_normalise(p_code text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(regexp_replace(COALESCE(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Issues a pass for a record. The caller is an agency office whose own account holds the record (it created
-- the record for a client who is not yet its owner in Meesam). An earlier unused pass for the record stops
-- working. Returns the code once; only its hash is stored.
CREATE FUNCTION core.fn_pass_issue(p_record_id uuid, p_sent_to citext DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); u core.app_user; a core.account; v_owner uuid; v_code text := ''; v_raw bytea; i int;
  c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- no 0/O, 1/I: the code is read and typed by people
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me;
  SELECT * INTO a FROM core.account WHERE id = me;
  IF u.id IS NULL OR u.status <> 'active' OR u.role NOT IN ('agency_admin', 'agent') OR a.kind <> 'agency_office' OR a.verified_at IS NULL THEN
    RAISE EXCEPTION 'only an agency administrator or agent issues an owner pass' USING ERRCODE = '42501';
  END IF;
  SELECT f.owner_account_id INTO v_owner FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id WHERE r.id = p_record_id;
  IF v_owner IS DISTINCT FROM me THEN
    RAISE EXCEPTION 'a pass is issued for a record the agency holds itself' USING ERRCODE = '22023';
  END IF;
  UPDATE core.owner_pass SET expires_at = now() WHERE record_id = p_record_id AND redeemed_at IS NULL AND expires_at > now();
  v_raw := gen_random_bytes(12);
  FOR i IN 0..11 LOOP v_code := v_code || substr(c_alphabet, (get_byte(v_raw, i) % 32) + 1, 1); END LOOP;
  INSERT INTO core.owner_pass (record_id, issued_by_account_id, token_hash, sent_to) VALUES (p_record_id, me, digest(v_code, 'sha256'), p_sent_to);
  RETURN substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
END $$;

-- What a valid code is for (shown before the owner confirms). Nothing for a used, expired or unknown code.
CREATE FUNCTION core.fn_pass_preview(p_code text)
RETURNS TABLE (record_id uuid, mark_text jsonb, registry_code text, number text, agency_name jsonb, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
  SELECT r.id, r.mark_text, g.code::text, COALESCE(r.registration_no, r.application_no), a.name, p.expires_at
    FROM core.owner_pass p JOIN core.record r ON r.id = p.record_id JOIN registry.registry g ON g.id = r.registry_id
    JOIN core.account a ON a.id = p.issued_by_account_id
   WHERE p.token_hash = digest(core.fn_pass_normalise(p_code), 'sha256') AND p.redeemed_at IS NULL AND p.expires_at > now()
$$;

-- Redeems a pass: the record becomes the caller's (an owner account), and the issuing agency goes on managing
-- it under an appointment in force with that record in scope, which the owner can end at any time.
-- A pass is bound to one record: if the agency kept the record in a family with others, the record moves to
-- a family of its own.
CREATE FUNCTION core.fn_pass_redeem(p_code text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); u core.app_user; a core.account; p core.owner_pass; f core.mark_family; v_family uuid; v_app uuid;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me;
  SELECT * INTO a FROM core.account WHERE id = me;
  IF u.id IS NULL OR u.status <> 'active' OR a.kind NOT IN ('owner_individual', 'owner_company') OR a.verified_at IS NULL THEN
    RAISE EXCEPTION 'a pass is redeemed by a verified owner account' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO p FROM core.owner_pass WHERE token_hash = digest(core.fn_pass_normalise(p_code), 'sha256') FOR UPDATE;
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
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_pass_normalise(text), core.fn_pass_issue(uuid, citext), core.fn_pass_preview(text), core.fn_pass_redeem(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_pass_normalise(text), core.fn_pass_issue(uuid, citext), core.fn_pass_preview(text), core.fn_pass_redeem(text) TO meesam_app;

COMMIT;
