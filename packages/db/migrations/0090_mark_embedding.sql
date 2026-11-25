-- 0090 — The vector of a published mark's picture is kept beside the mark (second step toward comparing pictures).
--
-- Founder ruling 25 Nov 2026 ("A"): the picture service starts with SigLIP 2 alone (Apache 2.0); DINOv3 is added
-- when its licence review (Data Architecture 14.20) is closed. The columns have been there since 0002
-- (siglip_embedding, dino_embedding, both 768 numbers; embedding_engine). This migration only lets the worker
-- store what the service returns. Nothing is compared yet: how a picture score becomes a band, and how it stands
-- beside the word score, is still to be ruled.
-- The engine's full name (model, the revision of its files, how the picture was prepared) is kept with every
-- vector, so vectors made by different engines are never compared with one another.
BEGIN;

CREATE FUNCTION watch.fn_mark_embedding_set(p_issue_id uuid, p_mark_id uuid, p_model text, p_vector text, p_engine text, p_phash text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
BEGIN
  IF p_model IS DISTINCT FROM 'siglip2' THEN RAISE EXCEPTION 'this model is not in use' USING ERRCODE = '22023'; END IF;
  IF p_engine IS NULL OR btrim(p_engine) = '' THEN RAISE EXCEPTION 'a vector must name its engine' USING ERRCODE = '22023'; END IF;
  UPDATE watch.published_mark
     SET siglip_embedding = p_vector::vector(768), embedding_engine = left(p_engine, 200),
         extraction = extraction || jsonb_strip_nulls(jsonb_build_object('image_phash', CASE WHEN p_phash ~ '^[0-9a-f]{16}$' THEN p_phash END, 'siglip_engine', left(p_engine, 200)))
   WHERE issue_id = p_issue_id AND id = p_mark_id AND extraction ? 'image_key';
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_mark_embedding_set(uuid, uuid, text, text, text, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_mark_embedding_set(uuid, uuid, text, text, text, text) TO meesam_worker;

-- a picture the service cannot open is noted on the mark, so it is not asked again and again
CREATE FUNCTION watch.fn_mark_embedding_failed(p_issue_id uuid, p_mark_id uuid, p_reason text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
  UPDATE watch.published_mark SET extraction = extraction || jsonb_build_object('embed_failed', left(COALESCE(p_reason, ''), 200))
   WHERE issue_id = p_issue_id AND id = p_mark_id AND extraction ? 'image_key'
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_mark_embedding_failed(uuid, uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_mark_embedding_failed(uuid, uuid, text) TO meesam_worker;

COMMIT;
