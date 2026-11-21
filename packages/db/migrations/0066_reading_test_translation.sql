-- 0066 — A reading test can also ask for a translation (Founder, 21 Nov 2026: the Qatar gazette is in Arabic;
-- can it be shown in other languages, by selection?). The test may name one language; the reader then gives,
-- beside what is printed, the applicant and agent names written in that language's script and the goods
-- translated. What is printed is never replaced: a translation is an aid beside the registry's own wording.
BEGIN;

ALTER TABLE watch.read_test ADD COLUMN translate_to text NULL CHECK (translate_to ~ '^[a-z]{2}$');

DROP FUNCTION watch.fn_read_test_request(uuid, integer, integer, text);
CREATE FUNCTION watch.fn_read_test_request(p_issue_id uuid, p_first_page integer, p_pages integer, p_model text, p_translate_to text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_model text := NULLIF(btrim(left(p_model, 80)), ''); v_lang text := NULLIF(lower(btrim(p_translate_to)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_model IS NULL OR v_model !~ '^[a-z0-9.-]+$' THEN RAISE EXCEPTION 'a model is required' USING ERRCODE = '22023'; END IF;
  IF v_lang IS NOT NULL AND v_lang !~ '^[a-z]{2}$' THEN RAISE EXCEPTION 'the language is a two-letter code' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM watch.publication_issue i WHERE i.id = p_issue_id AND i.object_key IS NOT NULL) THEN
    RAISE EXCEPTION 'no such stored issue' USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (SELECT 1 FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id
              JOIN watch.reuse_register r ON r.registry_id = s.registry_id WHERE i.id = p_issue_id AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow processing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  IF (SELECT count(*) FROM watch.read_test WHERE created_at > now() - interval '1 hour') >= 30 THEN
    RAISE EXCEPTION 'too many reading tests in the last hour' USING ERRCODE = '54000';
  END IF;
  INSERT INTO watch.read_test (issue_id, first_page, pages, model, requested_by, auto_start, translate_to)
  VALUES (p_issue_id, greatest(1, COALESCE(p_first_page, 1)), least(5, greatest(1, p_pages)), v_model, platform.current_user_id(),
          COALESCE(p_first_page, 0) < 1, v_lang)
  RETURNING id INTO v_id;
  PERFORM platform.enqueue_job('watch.read_test', jsonb_build_object('id', v_id), now(), 'watch.read_test:' || v_id);
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_read_test_request(uuid, integer, integer, text, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_read_test_request(uuid, integer, integer, text, text) TO meesam_staff, meesam_admin;

COMMIT;
