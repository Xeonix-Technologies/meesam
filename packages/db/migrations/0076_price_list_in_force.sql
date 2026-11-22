-- 0076 — The price list in force, in one place; and "is this trademark watched" reads it the same way as the prices.
-- Found 22 Nov 2026: Price List v1.0 takes effect on 2 Dec 2026, and before that date no list is "effective" by
-- date. The pricing engine (0059) then falls back to the newest list, but core.fn_record_watched (0069) did not, so
-- before 2 Dec an unpaid trademark was treated as not watched even though the pilot is free: no alert would have
-- been raised for it. Both now use the same rule: the newest list already in effect, else the newest list.
BEGIN;

CREATE FUNCTION core.fn_price_list_rules(p_as_of date DEFAULT current_date) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT COALESCE(
    (SELECT rules FROM core.price_list WHERE effective_from <= p_as_of ORDER BY effective_from DESC, version DESC LIMIT 1),
    (SELECT rules FROM core.price_list ORDER BY version DESC LIMIT 1))
$$;
REVOKE EXECUTE ON FUNCTION core.fn_price_list_rules(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_price_list_rules(date) TO meesam_app, meesam_staff, meesam_admin, meesam_worker;

CREATE OR REPLACE FUNCTION core.fn_record_watched(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT NOT r.terminal AND (r.paid_state = 'paid'
           OR (r.paid_state <> 'read_only_unpaid' AND COALESCE((core.fn_price_list_rules() ->> 'pilot_all_free')::boolean, false)))
    FROM core.record r WHERE r.id = p_record_id
$$;

-- trademarks that were skipped for this reason are compared now with what is already published
SELECT platform.enqueue_job('watch.compare_record', jsonb_build_object('record_id', r.id), now(), 'watch.compare_record:' || r.id)
  FROM core.record r WHERE NOT r.terminal AND r.paid_state NOT IN ('paid', 'read_only_unpaid');

COMMIT;
