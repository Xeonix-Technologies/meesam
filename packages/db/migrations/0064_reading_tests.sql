-- 0064 — Reading tests (plan item A1, first step; Founder ruling R2, 21 Nov 2026).
-- Before the reading stage is built in full, the watch operations lead can send a few pages of a stored issue to
-- the AI reader and see what comes back: which marks, numbers, classes and owners it reads, with which model and
-- at what size. A test stores nothing among the published marks and reaches no account; it is a look, not a load.
BEGIN;

CREATE TABLE watch.read_test (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id      uuid NOT NULL REFERENCES watch.publication_issue(id),
  first_page    integer NOT NULL CHECK (first_page >= 1),
  pages         integer NOT NULL CHECK (pages BETWEEN 1 AND 5),
  model         text NOT NULL,
  requested_by  uuid NULL REFERENCES core.app_user(id),
  status        text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
  started_at    timestamptz NULL,
  finished_at   timestamptz NULL,
  file_name     text NULL,        -- the file read (the one inside an archive, where the issue is an archive)
  page_count    integer NULL,     -- pages in that file
  input_tokens  integer NULL,
  output_tokens integer NULL,
  result        jsonb NULL,       -- {page_kind, marks: [...], notes}
  error         text NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON watch.read_test (created_at DESC);
ALTER TABLE watch.read_test ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_test_read ON watch.read_test FOR SELECT TO meesam_staff, meesam_admin, meesam_worker USING (true);
CREATE POLICY read_test_write ON watch.read_test FOR UPDATE TO meesam_worker USING (true) WITH CHECK (true);
GRANT SELECT ON watch.read_test TO meesam_staff, meesam_admin;
GRANT SELECT, UPDATE ON watch.read_test TO meesam_worker;

-- The lead asks for a test: the issue must be stored, and the registry's re-use register must allow storing
-- (the same gate as fetching: nothing of a registry is processed against its terms).
CREATE FUNCTION watch.fn_read_test_request(p_issue_id uuid, p_first_page integer, p_pages integer, p_model text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_model text := NULLIF(btrim(left(p_model, 80)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_model IS NULL OR v_model !~ '^[a-z0-9.-]+$' THEN RAISE EXCEPTION 'a model is required' USING ERRCODE = '22023'; END IF;
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
  INSERT INTO watch.read_test (issue_id, first_page, pages, model, requested_by)
  VALUES (p_issue_id, greatest(1, p_first_page), least(5, greatest(1, p_pages)), v_model, platform.current_user_id())
  RETURNING id INTO v_id;
  PERFORM platform.enqueue_job('watch.read_test', jsonb_build_object('id', v_id), now(), 'watch.read_test:' || v_id);
  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_read_test_request(uuid, integer, integer, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_read_test_request(uuid, integer, integer, text) TO meesam_staff, meesam_admin;

COMMIT;
