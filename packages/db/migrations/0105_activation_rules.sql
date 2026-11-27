-- 0105 — Activation: what it asks for, and which marks wait for it (Founder rulings 27 Nov 2026, second set, on
-- the four points left open by 0104).
--   b. "The image is required for the watch, asking for a clear image; the certificate is a must for registered
--      trademarks, to match the actual expiry dates for the fee calculation." So activation asks for the mark's
--      image always, and for a registered mark also its certificate: a document filed as Registration
--      certificate (ORC) or Renewal certificate (REN). "At least one document" (0104) is no longer the rule.
--      A mark counts as registered when it carries a registration number or date, or a registered or renewed event.
--   c. "Rules apply to all, even by hand." An existing trademark added one at a time through the application
--      starts not active too, like one loaded in bulk. Records that exist today stay as they are.
--   d. Any user except a Viewer may request activation and check the basket out (as built in 0104).
--   a. ("no information, only the mark name" before activation) is a matter of what the pages show; nothing here.
-- RULING NEEDED: a new filing made through Meesam (entry_mode new_filing) and a record received by an owner pass
-- are not touched by this rule: the price list gives the new filing its own path (AED 100 at filing).
-- RULING NEEDED: Meesam checks that the certificate is on the record, not yet that the expiry date typed on the
-- record is the one printed on it.
BEGIN;

CREATE OR REPLACE FUNCTION core.trg_record_activation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- loaded in bulk: always. Added by hand: when the application adds it (set-up data written by the owner of
    -- the database, as in the tests and seeds, keeps what it says).
    IF NEW.entry_mode = 'bulk_import' OR (NEW.entry_mode = 'existing' AND current_user = 'meesam_app') THEN NEW.activated_at := NULL; END IF;
    NEW.activation_requested_at := NULL; NEW.activation_requested_by := NULL;
  ELSIF current_user = 'meesam_app' AND (NEW.activated_at IS DISTINCT FROM OLD.activated_at
        OR NEW.activation_requested_at IS DISTINCT FROM OLD.activation_requested_at
        OR NEW.activation_requested_by IS DISTINCT FROM OLD.activation_requested_by) THEN
    RAISE EXCEPTION 'activation is changed through core.fn_activation_* only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;

-- What activation asks of one record, and what it has. Runs as the caller: it answers only for a record the caller can see.
DROP FUNCTION core.fn_activation_ready(uuid);
CREATE FUNCTION core.fn_activation_needs(p_record_id uuid, OUT has_image boolean, OUT needs_certificate boolean, OUT has_certificate boolean, OUT ready boolean)
LANGUAGE sql STABLE AS $$
  SELECT x.has_image, x.registered, x.has_certificate, x.has_image AND (NOT x.registered OR x.has_certificate)
    FROM (SELECT r.mark_image_doc_id IS NOT NULL AS has_image,
                 (r.registration_no IS NOT NULL OR r.registration_date IS NOT NULL
                   OR EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type IN ('registered', 'renewed'))) AS registered,
                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')) AS has_certificate
            FROM core.record r WHERE r.id = p_record_id) x
$$;
-- the same answer for the functions below, which run with the owner's rights on records already known to be the caller's
CREATE FUNCTION core.fn_activation_ready(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT COALESCE((SELECT n.ready FROM core.fn_activation_needs(p_record_id) n), false)
$$;
REVOKE EXECUTE ON FUNCTION core.fn_activation_ready(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_activation_needs(uuid) TO meesam_app;

CREATE OR REPLACE FUNCTION core.fn_activation_request(p_record_ids uuid[] DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM core.fn_activation_actor();
  UPDATE core.record r SET activation_requested_at = now(), activation_requested_by = platform.current_user_id()
   WHERE r.id IN (SELECT core.fn_my_inactive()) AND r.activated_at IS NULL AND r.activation_requested_at IS NULL
     AND (p_record_ids IS NULL OR r.id = ANY (p_record_ids))
     AND core.fn_activation_ready(r.id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION core.fn_activation_counts(OUT waiting integer, OUT ready integer, OUT in_basket integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT count(*) FILTER (WHERE r.activation_requested_at IS NULL)::int,
         count(*) FILTER (WHERE r.activation_requested_at IS NULL AND core.fn_activation_ready(r.id))::int,
         count(*) FILTER (WHERE r.activation_requested_at IS NOT NULL)::int
    FROM core.fn_my_inactive() h JOIN core.record r ON r.id = h
$$;

COMMIT;
