-- 0104 — A trademark loaded in bulk waits for activation; the basket (Founder ruling 27 Nov 2026).
-- "Uploading is free; the use of the uploaded information is not. When the agency has added the documents and
-- the mark's image, it requests activation; the mark goes to the basket, where several marks are paid together."
--
-- What this migration does:
--   * a record carries activated_at. Every record that exists today, and every record added one at a time or
--     filed through Meesam, is active as before. A record loaded by the bulk import starts not active.
--   * while a record is not active Meesam keeps what was uploaded and shows it, with its dates, but does not work
--     for it: no reminders (in Meesam or by e-mail), not in the calendar feed, not in the watch.
--   * activation is requested for a record that has the mark's image and at least one document; the request puts
--     it in the account's basket. Checking the basket out activates every record in it at once.
--   * payment: the price of each record in the basket is the price list's (core.fn_record_due). No payment
--     provider is connected yet, so checkout completes only while the price list says the pilot is free
--     (pilot_all_free, CLAUDE.md rule 9: "until ruled, the pilot stays everything free"); otherwise it refuses and
--     says payment is not open. Nothing is charged and no payment row is written by this migration.
-- RULING NEEDED (listed in docs/README.md, 27 Nov 2026): whether dates stay visible before activation; whether a
-- word mark with no picture may be activated; whether marks added one at a time and owners' bulk imports follow
-- the same rule; who in an account may check out.
BEGIN;

ALTER TABLE core.record
  ADD COLUMN activated_at            timestamptz NULL DEFAULT now(),
  ADD COLUMN activation_requested_at timestamptz NULL,
  ADD COLUMN activation_requested_by uuid NULL REFERENCES core.app_user(id);
COMMENT ON COLUMN core.record.activated_at IS 'when Meesam started working for this record (reminders, calendar feed, watch); NULL = loaded in bulk and waiting for activation';
COMMENT ON COLUMN core.record.activation_requested_at IS 'in the basket since; NULL = not requested';
CREATE INDEX record_in_basket ON core.record (activation_requested_at) WHERE activated_at IS NULL AND activation_requested_at IS NOT NULL;
CREATE INDEX record_not_active ON core.record (mark_family_id) WHERE activated_at IS NULL;

-- A record loaded in bulk starts not active, whatever the statement says; the app role never sets these columns itself.
CREATE FUNCTION core.trg_record_activation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.entry_mode = 'bulk_import' THEN NEW.activated_at := NULL; END IF;
    NEW.activation_requested_at := NULL; NEW.activation_requested_by := NULL;
  ELSIF current_user = 'meesam_app' AND (NEW.activated_at IS DISTINCT FROM OLD.activated_at
        OR NEW.activation_requested_at IS DISTINCT FROM OLD.activation_requested_at
        OR NEW.activation_requested_by IS DISTINCT FROM OLD.activation_requested_by) THEN
    RAISE EXCEPTION 'activation is changed through core.fn_activation_* only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER record_activation_ins BEFORE INSERT ON core.record FOR EACH ROW EXECUTE FUNCTION core.trg_record_activation();
CREATE TRIGGER record_activation_upd BEFORE UPDATE OF activated_at, activation_requested_at, activation_requested_by ON core.record
  FOR EACH ROW EXECUTE FUNCTION core.trg_record_activation();

-- Watched = as before (0076), and active.
CREATE OR REPLACE FUNCTION core.fn_record_watched(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT NOT r.terminal AND r.activated_at IS NOT NULL AND (r.paid_state = 'paid'
           OR (r.paid_state <> 'read_only_unpaid' AND COALESCE((core.fn_price_list_rules() ->> 'pilot_all_free')::boolean, false)))
    FROM core.record r WHERE r.id = p_record_id
$$;

-- Reminders (0035) and the calendar feed (0036): the same functions, for active records only.
CREATE OR REPLACE FUNCTION core.fn_reminders_materialise(p_now timestamptz DEFAULT now()) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE x record; n integer := 0; k integer; v_sev text; v_days integer; v_deadline date;
BEGIN
  FOR x IN
    WITH live AS (
      SELECT t.id AS timer_id, t.record_id, t.family, t.timer_type, t.due_date,
             COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC') AS tz, t.created_at
        FROM core.timer t
        JOIN core.record r ON r.id = t.record_id AND NOT r.terminal AND r.activated_at IS NOT NULL   -- 0104: a loaded mark not yet activated gets no reminders
        LEFT JOIN registry.registry_profile p ON p.registry_id = r.registry_id
       WHERE t.state = 'open' AND t.due_date IS NOT NULL AND NOT t.awaiting_user_entry AND t.family IN ('statutory', 'reminder')
    ), cal AS (
      SELECT l.*, (p_now AT TIME ZONE l.tz)::date AS today, (l.created_at AT TIME ZONE l.tz)::date AS born,
             COALESCE(c.at_start, d.at_start) AS at_start, COALESCE(c.months_before, d.months_before) AS months_before,
             COALESCE(c.days_before, d.days_before) AS days_before, COALESCE(c.on_due, d.on_due) AS on_due
        FROM live l
        LEFT JOIN platform.reminder_cadence c ON c.timer_type = l.timer_type
        JOIN platform.reminder_cadence d ON d.timer_type = '*'
    ), points AS (
      -- a reminder clock from the registry profile is itself the point
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'on'::text AS point, due_date AS point_date FROM cal WHERE family = 'reminder'
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'start', born FROM cal WHERE family = 'statutory' AND at_start AND due_date >= today
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'm' || m, (due_date - make_interval(months => m))::date
        FROM cal, unnest(months_before) m WHERE family = 'statutory'
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'd' || d, due_date - d FROM cal, unnest(days_before) d WHERE family = 'statutory'
      UNION ALL
      SELECT timer_id, record_id, timer_type, due_date, tz, today, born, 'due', due_date FROM cal WHERE family = 'statutory' AND on_due
    )
    -- the latest point that fell due for each clock
    SELECT DISTINCT ON (timer_id) * FROM points
     WHERE point_date <= today AND point_date >= today - 3 AND point_date >= born
     ORDER BY timer_id, point_date DESC, (point = 'start')
  LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM platform.notification q WHERE q.timer_id = x.timer_id AND q.point = x.point);
    -- days to the hard deadline this point is about: the clock itself, or for a renewal reminder the expiry it counts down to
    v_deadline := CASE WHEN x.timer_type LIKE '%\_reminder\_%m'
                       THEN COALESCE((SELECT min(t2.due_date) FROM core.timer t2 WHERE t2.record_id = x.record_id AND t2.timer_type = 'expiry' AND t2.state = 'open'), x.due_date)
                       ELSE x.due_date END;
    v_days := v_deadline - x.today;
    -- Section 4.11: Critical = a hard deadline inside 30 days (a calendar month is read as inside); a window opening = Important
    v_sev := CASE WHEN x.timer_type = 'renewal_window' THEN 'important' WHEN v_days <= 31 THEN 'critical' ELSE 'important' END;

    INSERT INTO platform.notification (account_id, channel, kind, record_id, severity, timer_id, point, dedupe_key, payload)
    SELECT a.account_id, 'in_app', 'timer_due', x.record_id, v_sev, x.timer_id, x.point,
           format('rem:%s:%s:a:%s', x.timer_id, x.point, a.account_id),
           jsonb_build_object('timer_type', x.timer_type, 'due_date', v_deadline, 'days', v_days, 'timezone', x.tz)
      FROM (SELECT DISTINCT account_id FROM core.v_record_access WHERE record_id = x.record_id) a
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

    -- recipients (4.11): the Administrator and, while records are not assigned to users, every Agent and
    -- Trademark manager of each account that reaches the record; a Viewer receives nothing
    INSERT INTO platform.notification (account_id, user_id, channel, kind, record_id, severity, timer_id, point, dedupe_key, payload)
    SELECT u.account_id, u.id, 'email', 'timer_due', x.record_id, v_sev, x.timer_id, x.point,
           format('rem:%s:%s:u:%s', x.timer_id, x.point, u.id),
           jsonb_build_object('timer_type', x.timer_type, 'due_date', v_deadline, 'days', v_days, 'timezone', x.tz)
      FROM (SELECT DISTINCT account_id FROM core.v_record_access WHERE record_id = x.record_id) a
      JOIN core.app_user u ON u.account_id = a.account_id AND u.status = 'active' AND u.role <> 'viewer'
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  END LOOP;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION core.fn_calendar_events(p_token_hash bytea)
RETURNS TABLE (locale text, account_id uuid, timer_id uuid, record_id uuid, timer_type text, due_date date, timezone text,
               mark_text jsonb, number text, registry_code text, updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE u core.app_user;
BEGIN
  SELECT au.* INTO u FROM core.calendar_feed f JOIN core.app_user au ON au.id = f.user_id JOIN core.account a ON a.id = au.account_id
   WHERE f.token_hash = p_token_hash AND au.status = 'active' AND au.role <> 'viewer' AND a.verified_at IS NOT NULL;
  IF u.id IS NULL THEN RETURN; END IF;
  UPDATE core.calendar_feed f SET last_read_at = now() WHERE f.user_id = u.id;
  -- a first row with no date carries the reader's language even when there is nothing to show
  RETURN QUERY SELECT u.locale, u.account_id, NULL::uuid, NULL::uuid, NULL::text, NULL::date, NULL::text, NULL::jsonb, NULL::text, NULL::text, NULL::timestamptz;
  RETURN QUERY
    SELECT u.locale, u.account_id, t.id, t.record_id, t.timer_type, t.due_date, COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC'),
           r.mark_text, COALESCE(r.registration_no, r.application_no), g.code::text, t.updated_at
      FROM core.timer t
      JOIN core.record r ON r.id = t.record_id AND NOT r.terminal AND r.activated_at IS NOT NULL   -- 0104
      JOIN registry.registry g ON g.id = r.registry_id
      LEFT JOIN registry.registry_profile p ON p.registry_id = r.registry_id
     WHERE t.state = 'open' AND t.due_date IS NOT NULL AND t.family = 'statutory'
       AND core.fn_can_access(t.record_id, u.account_id)
     ORDER BY t.due_date;
END $$;

-- What activation asks for: the mark's own image, and at least one document (not counting the image).
-- Runs as the caller, so it answers only for a record the caller can see.
CREATE FUNCTION core.fn_activation_ready(p_record_id uuid, OUT has_image boolean, OUT has_document boolean)
LANGUAGE sql STABLE AS $$
  SELECT r.mark_image_doc_id IS NOT NULL,
         EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type <> 'IMG')
    FROM core.record r WHERE r.id = p_record_id
$$;

-- The caller may act on activation: an active user of the account, not a Viewer.
CREATE FUNCTION core.fn_activation_actor() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v_account uuid := platform.current_account_id();
BEGIN
  IF v_account IS NULL OR NOT EXISTS (SELECT 1 FROM core.app_user u JOIN core.account a ON a.id = u.account_id
       WHERE u.id = platform.current_user_id() AND u.account_id = v_account AND u.status = 'active' AND u.role <> 'viewer' AND a.verified_at IS NOT NULL) THEN
    RAISE EXCEPTION 'not allowed to activate trademarks' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_account;
END $$;

-- The records the calling account holds (its own families, or under an appointment in force) that are not active
-- and not closed. Found from the account outward, so the cost follows the account's own marks, not everyone's.
CREATE FUNCTION core.fn_my_inactive() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT r.id FROM core.mark_family f JOIN core.record r ON r.mark_family_id = f.id
   WHERE f.owner_account_id = platform.current_account_id() AND r.activated_at IS NULL AND NOT r.terminal
  UNION
  SELECT r.id FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
    JOIN core.record r ON r.id = ar.record_id
   WHERE a.agency_account_id = platform.current_account_id() AND a.status = 'accepted' AND a.ended_at IS NULL AND r.activated_at IS NULL AND NOT r.terminal
$$;

-- Puts records in the basket: the ones named, or (NULL) every record of the account that is ready. A record that is
-- not held by the account, already active, closed, already in the basket or not ready is passed over.
-- Returns how many went in.
CREATE FUNCTION core.fn_activation_request(p_record_ids uuid[] DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM core.fn_activation_actor();
  UPDATE core.record r SET activation_requested_at = now(), activation_requested_by = platform.current_user_id()
   WHERE r.id IN (SELECT core.fn_my_inactive()) AND r.activated_at IS NULL AND r.activation_requested_at IS NULL
     AND (p_record_ids IS NULL OR r.id = ANY (p_record_ids))
     AND r.mark_image_doc_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type <> 'IMG');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Takes one record out of the basket again.
CREATE FUNCTION core.fn_activation_withdraw(p_record_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM core.fn_activation_actor();
  UPDATE core.record r SET activation_requested_at = NULL, activation_requested_by = NULL
   WHERE r.id = p_record_id AND r.id IN (SELECT core.fn_my_inactive()) AND r.activation_requested_at IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END $$;

-- The account's marks that are not active: how many wait, how many of those are ready, how many are in the basket.
CREATE FUNCTION core.fn_activation_counts(OUT waiting integer, OUT ready integer, OUT in_basket integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT count(*) FILTER (WHERE r.activation_requested_at IS NULL)::int,
         count(*) FILTER (WHERE r.activation_requested_at IS NULL AND r.mark_image_doc_id IS NOT NULL
                            AND EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type <> 'IMG'))::int,
         count(*) FILTER (WHERE r.activation_requested_at IS NOT NULL)::int
    FROM core.fn_my_inactive() h JOIN core.record r ON r.id = h
$$;

-- The basket: each record waiting to be activated, with today's price from the price list in force.
-- Runs as the caller: row-level security on records applies, and the price is the one the caller is shown elsewhere.
CREATE FUNCTION core.fn_basket()
RETURNS TABLE (record_id uuid, mark_text jsonb, registry_code text, number text, client text, requested_at timestamptz,
               years_remaining smallint, list_amount numeric, amount numeric, introductory boolean, due numeric, vat numeric, total numeric, vat_inclusive boolean)
LANGUAGE sql STABLE AS $$
  SELECT r.id, r.mark_text, g.code::text, COALESCE(r.registration_no, r.application_no),
         (SELECT c.name FROM core.mark_family f JOIN core.client c ON c.id = f.client_id WHERE f.id = r.mark_family_id),
         r.activation_requested_at, d.years_remaining, d.list_amount, d.amount, d.introductory, d.due, d.vat, d.total, d.vat_inclusive
    FROM core.fn_my_inactive() h JOIN core.record r ON r.id = h JOIN registry.registry g ON g.id = r.registry_id
    LEFT JOIN LATERAL core.fn_record_due(r.id, current_date, false) d ON true
   WHERE r.activation_requested_at IS NOT NULL
   ORDER BY r.activation_requested_at, r.id
$$;

-- Is payment open? Not yet: no provider is connected. While the price list says the pilot is free, nothing is due.
CREATE FUNCTION core.fn_basket_free() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT COALESCE((core.fn_price_list_rules() ->> 'pilot_all_free')::boolean, false)
$$;

-- Checks the basket out: every record in it becomes active at once and is compared with what is already published.
-- Completes only while nothing is due (the pilot); with a price due and no payment provider it refuses.
CREATE FUNCTION core.fn_basket_checkout() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v uuid; n integer := 0;
BEGIN
  PERFORM core.fn_activation_actor();
  IF NOT core.fn_basket_free() THEN
    RAISE EXCEPTION 'payment is not open yet' USING ERRCODE = 'feature_not_supported';
  END IF;
  FOR v IN UPDATE core.record r SET activated_at = now()
            WHERE r.id IN (SELECT core.fn_my_inactive()) AND r.activated_at IS NULL AND r.activation_requested_at IS NOT NULL
           RETURNING r.id LOOP
    PERFORM platform.enqueue_job('watch.compare_record', jsonb_build_object('record_id', v), now() + interval '1 minute', 'watch.compare_record:' || v);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION core.fn_activation_ready(uuid), core.fn_activation_actor(), core.fn_my_inactive(), core.fn_activation_request(uuid[]), core.fn_activation_withdraw(uuid),
                           core.fn_activation_counts(), core.fn_basket_free(), core.fn_basket_checkout() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_activation_ready(uuid), core.fn_my_inactive(), core.fn_activation_request(uuid[]), core.fn_activation_withdraw(uuid),
                          core.fn_activation_counts(), core.fn_basket(), core.fn_basket_free(), core.fn_basket_checkout() TO meesam_app;

COMMIT;
