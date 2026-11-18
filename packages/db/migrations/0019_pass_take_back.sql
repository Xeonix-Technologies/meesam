-- 0019 — Taking back a record handed over by an owner pass (Founder ruling 18 Nov 2026).
-- The side that issued the pass can take the record back, without the other side confirming, and the
-- appointment the pass created ends automatically. For a pass attached to the wrong owner account.
--
-- Bounds taken from the rules already in force (narrowest reading):
--   * only the agency office that issued the redeemed pass, and only for the account that redeemed it;
--   * only while that agency still manages the record: once the owner has ended the appointment the agency
--     has no access at all to the record (item 38), so it cannot take it back either;
--   * the record leaves the appointment's scope; the appointment itself ends when it covers nothing else
--     (it may cover other trademarks of the same owner, which are not touched).
BEGIN;

ALTER TABLE core.owner_pass ADD COLUMN IF NOT EXISTS taken_back_at timestamptz NULL;

-- Whether the caller (an agency) can take this record back now: it issued the pass by which the present
-- owner holds the record, and it still manages the record.
CREATE FUNCTION core.fn_pass_can_take_back(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.owner_pass p JOIN core.record r ON r.id = p.record_id JOIN core.mark_family f ON f.id = r.mark_family_id
     WHERE p.record_id = p_record_id AND p.issued_by_account_id = platform.current_account_id()
       AND p.redeemed_at IS NOT NULL AND p.taken_back_at IS NULL AND f.owner_account_id = p.redeemed_by_account_id
       AND platform.current_account_id() IN (SELECT core.fn_holding_agencies(p_record_id)))
$$;

-- Takes the record back into the issuing agency's own account. Returns the owner's users to tell by e-mail.
CREATE FUNCTION core.fn_pass_take_back(p_record_id uuid)
RETURNS TABLE (email citext, name text, locale text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE me uuid := platform.current_account_id(); u core.app_user; p core.owner_pass; f core.mark_family; v_owner uuid; v_family uuid; ap record;
BEGIN
  SELECT * INTO u FROM core.app_user WHERE id = platform.current_user_id() AND account_id = me;
  IF u.id IS NULL OR u.status <> 'active' OR u.role NOT IN ('agency_admin', 'agent') THEN
    RAISE EXCEPTION 'only an agency administrator or agent takes a record back' USING ERRCODE = '42501';
  END IF;
  IF NOT core.fn_pass_can_take_back(p_record_id) THEN
    RAISE EXCEPTION 'this record cannot be taken back' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO p FROM core.owner_pass WHERE record_id = p_record_id AND issued_by_account_id = me AND redeemed_at IS NOT NULL AND taken_back_at IS NULL
   ORDER BY redeemed_at DESC LIMIT 1 FOR UPDATE;
  v_owner := p.redeemed_by_account_id;
  SELECT fam.* INTO f FROM core.record r JOIN core.mark_family fam ON fam.id = r.mark_family_id WHERE r.id = p_record_id FOR UPDATE OF fam;

  -- the record returns to the agency's own account (a family of its own if the owner grouped it with others)
  IF (SELECT count(*) FROM core.record WHERE mark_family_id = f.id) > 1 THEN
    INSERT INTO core.mark_family (owner_account_id, name, mark_type) VALUES (me, f.name, f.mark_type) RETURNING id INTO v_family;
    UPDATE core.record SET mark_family_id = v_family WHERE id = p_record_id;
  ELSE
    UPDATE core.mark_family SET owner_account_id = me WHERE id = f.id;
  END IF;
  UPDATE core.owner_pass SET taken_back_at = now() WHERE id = p.id;

  -- it leaves the appointment; an appointment left with no trademark ends
  FOR ap IN SELECT a.id FROM core.appointment a WHERE a.owner_account_id = v_owner AND a.agency_account_id = me AND a.status = 'accepted' AND a.ended_at IS NULL FOR UPDATE LOOP
    UPDATE core.appointment_record SET removed_at = now() WHERE appointment_id = ap.id AND record_id = p_record_id AND removed_at IS NULL;
    IF NOT EXISTS (SELECT 1 FROM core.appointment_record WHERE appointment_id = ap.id AND removed_at IS NULL) THEN
      UPDATE core.appointment SET status = 'ended', ended_at = now(), ended_by = 'agency' WHERE id = ap.id;
    END IF;
  END LOOP;

  INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
  VALUES (v_owner, 'in_app', 'pass_taken_back', p_record_id, jsonb_build_object('by_account', me, 'by', u.name));
  RETURN QUERY SELECT x.email, x.name, x.locale FROM core.app_user x WHERE x.account_id = v_owner AND x.status = 'active' AND x.role <> 'viewer';
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_pass_can_take_back(uuid), core.fn_pass_take_back(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_pass_can_take_back(uuid), core.fn_pass_take_back(uuid) TO meesam_app;

COMMIT;
