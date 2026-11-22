-- 0075 — Reading some pages of an issue (Founder, 22 Nov 2026: testing the watch with real cases in the UAE and
-- Türkiye). The lead may ask for a range of pages instead of the whole issue: the marks on those pages are stored
-- waiting for verification like any others, at a fraction of the cost of a whole issue. Where the registry's layout
-- is not entered yet (the issue cannot be cut into its entries), up to 12 pages can still be read, as one request.
-- A reading of some pages is not compared with the registry's index.
BEGIN;

ALTER TABLE watch.read_run ADD COLUMN from_page integer NULL, ADD COLUMN to_page integer NULL;
ALTER TABLE watch.read_run ADD CONSTRAINT read_run_pages CHECK ((from_page IS NULL AND to_page IS NULL) OR (from_page >= 1 AND to_page >= from_page));

DROP FUNCTION watch.fn_read_run_request(uuid, text, bigint);
CREATE FUNCTION watch.fn_read_run_request(p_issue_id uuid, p_model text, p_token_cap bigint DEFAULT 3000000, p_from_page integer DEFAULT NULL, p_to_page integer DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_model text := NULLIF(btrim(left(p_model, 80)), ''); i record;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_model IS NULL OR v_model !~ '^[a-z0-9.-]+$' THEN RAISE EXCEPTION 'a model is required' USING ERRCODE = '22023'; END IF;
  SELECT x.id, x.published_on, s.registry_id, COALESCE(s.fetch_spec -> 'read' ->> 'entry_start', s.fetch_spec -> 'read' ->> 'entry_marker') AS marker INTO i
    FROM watch.publication_issue x JOIN watch.publication_source s ON s.id = x.source_id
   WHERE x.id = p_issue_id AND x.object_key IS NOT NULL;
  IF i.id IS NULL THEN RAISE EXCEPTION 'no such stored issue' USING ERRCODE = 'P0002'; END IF;
  IF EXISTS (SELECT 1 FROM watch.reuse_register r WHERE r.registry_id = i.registry_id AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow processing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  IF (p_from_page IS NULL) <> (p_to_page IS NULL) OR p_from_page < 1 OR p_to_page < p_from_page OR p_to_page - p_from_page + 1 > 400 THEN
    RAISE EXCEPTION 'give both a first and a last page, at most 400 pages' USING ERRCODE = '22023';
  END IF;
  -- the registry's layout must be entered to cut an issue into its entries; without it only a few pages can be read at a time
  IF i.marker IS NULL AND (p_from_page IS NULL OR p_to_page - p_from_page + 1 > 12) THEN
    RAISE EXCEPTION 'the layout of this registry''s bulletin is not entered yet' USING ERRCODE = '55000';
  END IF;
  -- a published mark is stored under its publication date
  IF i.published_on IS NULL THEN RAISE EXCEPTION 'the issue has no publication date' USING ERRCODE = '22004'; END IF;
  IF EXISTS (SELECT 1 FROM watch.read_run r WHERE r.issue_id = p_issue_id AND r.status IN ('queued', 'reading')) THEN
    RAISE EXCEPTION 'this issue is already being read' USING ERRCODE = '23505';
  END IF;
  IF (SELECT count(*) FROM watch.read_run WHERE created_at > now() - interval '24 hours') >= 6 THEN
    RAISE EXCEPTION 'too many full readings in the last day' USING ERRCODE = '54000';
  END IF;
  INSERT INTO watch.read_run (issue_id, model, requested_by, token_cap, from_page, to_page)
  VALUES (p_issue_id, v_model, platform.current_user_id(), least(20000000, greatest(100000, COALESCE(p_token_cap, 3000000))), p_from_page, p_to_page)
  RETURNING id INTO v_id;
  PERFORM platform.enqueue_job('watch.read_run', jsonb_build_object('id', v_id, 'step', 0), now(), 'watch.read_run:' || v_id || ':0');
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_read_run_request(uuid, text, bigint, integer, integer) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_read_run_request(uuid, text, bigint, integer, integer) TO meesam_staff, meesam_admin;

COMMIT;
