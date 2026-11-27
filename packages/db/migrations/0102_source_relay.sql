-- 0102 — A source fetched through a relay (Founder, 27 Nov 2026).
--
-- Some registries answer only networks inside their own country or region; the worker runs elsewhere. A relay is
-- a small server of Meesam's own inside that country, with a fixed address, that carries the fetcher's requests.
-- Which source goes through which relay is data on the source (fetch_spec.via, a short name such as "SA"), set by
-- the watch operations lead; where the relay is and how to sign in to it is configuration of the worker
-- (FETCH_RELAY_<NAME>), never data. The request stays Meesam's own, under Meesam's name; the re-use gate and the
-- robots rule apply exactly as before.
BEGIN;

CREATE FUNCTION watch.fn_source_via(p_source_id uuid, p_via text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v text := NULLIF(upper(btrim(COALESCE(p_via, ''))), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v IS NOT NULL AND v !~ '^[A-Z0-9_]{2,20}$' THEN RAISE EXCEPTION 'a relay name is 2 to 20 letters, digits or underscores' USING ERRCODE = '22023'; END IF;
  UPDATE watch.publication_source
     SET fetch_spec = CASE WHEN v IS NULL THEN fetch_spec - 'via' ELSE jsonb_set(fetch_spec, '{via}', to_jsonb(v), true) END, updated_at = now()
   WHERE id = p_source_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such source' USING ERRCODE = 'P0002'; END IF;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_source_via(uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_source_via(uuid, text) TO meesam_staff;

COMMIT;
