-- 0111 — A registry's number is locked by the active trademark (Founder ruling 28 Nov 2026: "A with the lock at
-- activation").
-- Until now a number at a registry could be on one record in all of Meesam, active or not. Uploading is free, so
-- an account could enter a number that is not its own and keep the true holder out. Ruled:
--   * only an ACTIVE trademark holds its number in all of Meesam: one registry, one number, one active record;
--   * marks that are not active do not hold it: several accounts may each have entered the same number;
--   * inside one account a number is still entered once (a file loaded twice does not double the portfolio);
--   * once a mark is active, the number can no longer be entered or corrected onto another record, and a copy
--     another account entered earlier gives way: it stays where it is, shows that the number is active in
--     Meesam, and cannot be put in the basket or activated. Its account's administrator can remove it (0110).
-- How: the unique rule on (registry, number) now counts active records only, and a check on the record table
-- refuses the other two cases. The check and the index both answer with a unique violation (23505); the
-- constraint name says which rule it was: record_one_per_application (two active), record_number_active (the
-- number is on an active trademark of another holder), record_number_account (already in this account).
-- A waiting copy is not written to when another account activates: nothing of one account changes a record of
-- another. The copy is simply left out of the basket and of checkout from then on.
BEGIN;

DROP INDEX core.record_one_per_application;
CREATE UNIQUE INDEX record_one_per_application ON core.record (registry_id, application_no)
  WHERE application_no IS NOT NULL AND removed_at IS NULL AND activated_at IS NOT NULL;
CREATE INDEX record_application_no ON core.record (registry_id, application_no) WHERE application_no IS NOT NULL AND removed_at IS NULL;

CREATE FUNCTION core.trg_record_number_rule() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v_owner uuid;
BEGIN
  IF NEW.application_no IS NULL OR NEW.removed_at IS NOT NULL THEN RETURN NULL; END IF;
  IF TG_OP = 'UPDATE' AND NEW.registry_id = OLD.registry_id AND NEW.application_no IS NOT DISTINCT FROM OLD.application_no
     AND NEW.mark_family_id = OLD.mark_family_id AND OLD.removed_at IS NULL THEN
    RETURN NULL;
  END IF;
  -- one writer at a time for one number at one registry
  PERFORM pg_advisory_xact_lock(hashtextextended('record_number:' || NEW.registry_id::text || ':' || NEW.application_no, 0));
  IF NEW.activated_at IS NULL AND EXISTS (SELECT 1 FROM core.record o WHERE o.registry_id = NEW.registry_id AND o.application_no = NEW.application_no
                                             AND o.id <> NEW.id AND o.removed_at IS NULL AND o.activated_at IS NOT NULL) THEN
    RAISE EXCEPTION 'this number is on an active trademark in Meesam' USING ERRCODE = 'unique_violation', CONSTRAINT = 'record_number_active';
  END IF;
  v_owner := core.fn_family_owner(NEW.mark_family_id);
  IF EXISTS (SELECT 1 FROM core.record o JOIN core.mark_family f ON f.id = o.mark_family_id
              WHERE o.registry_id = NEW.registry_id AND o.application_no = NEW.application_no AND o.id <> NEW.id AND o.removed_at IS NULL
                AND f.owner_account_id = v_owner) THEN
    RAISE EXCEPTION 'this number is already in this account' USING ERRCODE = 'unique_violation', CONSTRAINT = 'record_number_account';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER record_number_rule AFTER INSERT OR UPDATE OF registry_id, application_no, mark_family_id, removed_at ON core.record
  FOR EACH ROW EXECUTE FUNCTION core.trg_record_number_rule();

-- Is the number of this waiting record on an active trademark of someone else? Only for a record the caller holds.
CREATE FUNCTION core.fn_number_taken(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM core.record r JOIN core.record o ON o.registry_id = r.registry_id AND o.application_no = r.application_no AND o.id <> r.id
                  WHERE r.id = p_record_id AND r.activated_at IS NULL AND r.removed_at IS NULL AND o.activated_at IS NOT NULL AND o.removed_at IS NULL
                    AND core.fn_i_hold_record(r.id))
$$;
REVOKE EXECUTE ON FUNCTION core.fn_number_taken(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_number_taken(uuid) TO meesam_app;

-- a record whose number is active elsewhere is not put in the basket (0105)
CREATE OR REPLACE FUNCTION core.fn_activation_request(p_record_ids uuid[] DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM core.fn_activation_actor();
  UPDATE core.record r SET activation_requested_at = now(), activation_requested_by = platform.current_user_id()
   WHERE r.id IN (SELECT core.fn_my_inactive()) AND r.activated_at IS NULL AND r.activation_requested_at IS NULL
     AND (p_record_ids IS NULL OR r.id = ANY (p_record_ids))
     AND core.fn_activation_ready(r.id) AND NOT core.fn_number_taken(r.id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- nor counted as ready (0105)
CREATE OR REPLACE FUNCTION core.fn_activation_counts(OUT waiting integer, OUT ready integer, OUT in_basket integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT count(*) FILTER (WHERE r.activation_requested_at IS NULL)::int,
         count(*) FILTER (WHERE r.activation_requested_at IS NULL AND core.fn_activation_ready(r.id) AND NOT core.fn_number_taken(r.id))::int,
         count(*) FILTER (WHERE r.activation_requested_at IS NOT NULL)::int
    FROM core.fn_my_inactive() h JOIN core.record r ON r.id = h
$$;

-- Checkout (0104): a record whose number became active elsewhere while it waited in the basket is taken out of the
-- basket first, by its own account, and the rest is activated.
CREATE OR REPLACE FUNCTION core.fn_basket_checkout() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v uuid; n integer := 0;
BEGIN
  PERFORM core.fn_activation_actor();
  IF NOT core.fn_basket_free() THEN
    RAISE EXCEPTION 'payment is not open yet' USING ERRCODE = 'feature_not_supported';
  END IF;
  UPDATE core.record r SET activation_requested_at = NULL, activation_requested_by = NULL
   WHERE r.id IN (SELECT core.fn_my_inactive()) AND r.activated_at IS NULL AND r.activation_requested_at IS NOT NULL AND core.fn_number_taken(r.id);
  FOR v IN UPDATE core.record r SET activated_at = now()
            WHERE r.id IN (SELECT core.fn_my_inactive()) AND r.activated_at IS NULL AND r.activation_requested_at IS NOT NULL
           RETURNING r.id LOOP
    PERFORM platform.enqueue_job('watch.compare_record', jsonb_build_object('record_id', v), now() + interval '1 minute', 'watch.compare_record:' || v);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

COMMIT;
