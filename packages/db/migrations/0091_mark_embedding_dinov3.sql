-- 0091 — The DINOv3 vector of a mark's picture is kept too.
--
-- Founder, 25 Nov 2026: Meta's DINOv3 License is accepted and access to the model's files was granted to the
-- company's account the same day. The picture service gives a DINOv3 vector where its files are in the image;
-- the worker keeps it in dino_embedding (there since 0002), beside the SigLIP 2 vector, each with the name of the
-- engine that made it. Needs pgvector. Nothing is compared yet.
BEGIN;

CREATE OR REPLACE FUNCTION watch.fn_mark_embedding_set(p_issue_id uuid, p_mark_id uuid, p_model text, p_vector text, p_engine text, p_phash text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
BEGIN
  IF p_model IS NULL OR p_model NOT IN ('siglip2', 'dinov3') THEN RAISE EXCEPTION 'this model is not in use' USING ERRCODE = '22023'; END IF;
  IF p_engine IS NULL OR btrim(p_engine) = '' THEN RAISE EXCEPTION 'a vector must name its engine' USING ERRCODE = '22023'; END IF;
  IF p_model = 'siglip2' THEN
    UPDATE watch.published_mark
       SET siglip_embedding = p_vector::vector(768), embedding_engine = left(p_engine, 200),
           extraction = extraction || jsonb_strip_nulls(jsonb_build_object('image_phash', CASE WHEN p_phash ~ '^[0-9a-f]{16}$' THEN p_phash END, 'siglip_engine', left(p_engine, 200)))
     WHERE issue_id = p_issue_id AND id = p_mark_id AND extraction ? 'image_key';
  ELSE
    UPDATE watch.published_mark
       SET dino_embedding = p_vector::vector(768),
           extraction = extraction || jsonb_strip_nulls(jsonb_build_object('image_phash', CASE WHEN p_phash ~ '^[0-9a-f]{16}$' THEN p_phash END, 'dino_engine', left(p_engine, 200)))
     WHERE issue_id = p_issue_id AND id = p_mark_id AND extraction ? 'image_key';
  END IF;
END $$;

COMMIT;
