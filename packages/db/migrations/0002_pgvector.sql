-- =============================================================================
-- Meesam — migration 0002: image embeddings (Data Architecture Section 8 storage choices; item 14.3)
-- Requires the pgvector extension (Railway template "Postgres + pgvector"; CI uses pgvector/pgvector:pg18).
-- Two vectors per image, never compared to each other: DINOv3 ViT-B/16 (image-to-image) and
-- SigLIP 2 base (image–text cross-mode), both 768-d, each with its own HNSW index; pHash for exact copies.
-- Dimensions change only if a larger variant is chosen at build (then a new migration re-embeds).
-- =============================================================================
BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE watch.published_mark
  ADD COLUMN dino_embedding   vector(768) NULL,
  ADD COLUMN siglip_embedding vector(768) NULL,
  ADD COLUMN embedding_engine text NULL;            -- engine_version that produced the vectors

CREATE INDEX published_mark_dino_hnsw   ON watch.published_mark USING hnsw (dino_embedding vector_cosine_ops);
CREATE INDEX published_mark_siglip_hnsw ON watch.published_mark USING hnsw (siglip_embedding vector_cosine_ops);

-- The record side: one row per mark image document, raw backbone embeddings kept (14.3 item 1),
-- image stored normalised once alongside the original (14.3 item 2).
CREATE TABLE core.record_image (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id        uuid NOT NULL REFERENCES core.record(id),
  document_id      uuid NOT NULL UNIQUE REFERENCES core.document(id),
  normalised_key   text NULL,                       -- object key of the fixed-resolution working copy
  phash            bytea NULL,
  dino_embedding   vector(768) NULL,
  siglip_embedding vector(768) NULL,
  embedding_engine text NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.record_image (record_id);
CREATE INDEX record_image_dino_hnsw   ON core.record_image USING hnsw (dino_embedding vector_cosine_ops);
CREATE INDEX record_image_siglip_hnsw ON core.record_image USING hnsw (siglip_embedding vector_cosine_ops);
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON core.record_image FOR EACH ROW EXECUTE FUNCTION platform.touch_updated_at();

ALTER TABLE core.record_image ENABLE ROW LEVEL SECURITY;
CREATE POLICY record_image_select ON core.record_image FOR SELECT TO meesam_app USING (core.fn_can_access(record_id, platform.current_account_id()));
GRANT SELECT ON core.record_image TO meesam_app, meesam_staff, meesam_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON core.record_image TO meesam_worker, meesam_admin;

COMMIT;
