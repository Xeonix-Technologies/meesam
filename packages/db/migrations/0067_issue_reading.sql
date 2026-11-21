-- 0067 — Reading a whole issue (plan item A1; Founder rulings R2 and of 21 Nov 2026: read "at once" while testing;
-- the mark's own wording is never translated).
-- The watch operations lead asks for a stored issue to be read in full. The worker finds the pages where entries
-- begin (the registry's own marker, fetch_spec.read.entry_start), cuts the issue into parts at those pages, sends
-- each part to the AI reader and stores every mark it reads among the published marks as "ai_extracted": waiting
-- for a person to verify it. A mark in that state reaches no account, no match and no alert (0061 and the watch
-- rules); only verification releases it. Where the registry prints an index at the front (fetch_spec.read.index),
-- the index is read too and compared with the marks read, so a missed mark is seen and not assumed away.
-- A run carries a ceiling on its size (token_cap): it stops itself when it is reached, and the lead can stop it.
BEGIN;

CREATE TABLE watch.read_run (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id      uuid NOT NULL REFERENCES watch.publication_issue(id),
  model         text NOT NULL,
  status        text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'reading', 'done', 'failed', 'stopped')),
  requested_by  uuid NULL REFERENCES core.app_user(id),
  file_name     text NULL,
  page_count    integer NULL,
  first_page    integer NULL,                 -- first page of entries, found from the file
  entries_found integer NULL,                 -- pages on which an entry begins, found from the file's own text
  parts_total   integer NOT NULL DEFAULT 0,
  input_tokens  bigint NOT NULL DEFAULT 0,
  output_tokens bigint NOT NULL DEFAULT 0,
  token_cap     bigint NOT NULL CHECK (token_cap > 0),
  outcome       jsonb NULL,                   -- the comparison with the index, written when the run ends
  error         text NULL,
  started_at    timestamptz NULL,
  finished_at   timestamptz NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON watch.read_run (created_at DESC);
CREATE UNIQUE INDEX read_run_one_active ON watch.read_run (issue_id) WHERE status IN ('queued', 'reading');

-- One part of a run: a range of pages sent in one request. 'index' parts are the pages before the entries.
CREATE TABLE watch.read_part (
  run_id        uuid NOT NULL REFERENCES watch.read_run(id) ON DELETE CASCADE,
  seq           integer NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('index', 'entries')),
  from_page     integer NOT NULL CHECK (from_page >= 1),
  to_page       integer NOT NULL,
  status        text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'done', 'failed')),
  attempts      integer NOT NULL DEFAULT 0,
  input_tokens  integer NULL,
  output_tokens integer NULL,
  result        jsonb NULL,
  error         text NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (run_id, seq),
  CHECK (to_page >= from_page)
);

ALTER TABLE watch.read_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE watch.read_part ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_run_read ON watch.read_run FOR SELECT TO meesam_staff, meesam_admin, meesam_worker USING (true);
CREATE POLICY read_run_write ON watch.read_run FOR UPDATE TO meesam_worker USING (true) WITH CHECK (true);
CREATE POLICY read_part_read ON watch.read_part FOR SELECT TO meesam_staff, meesam_admin, meesam_worker USING (true);
CREATE POLICY read_part_add ON watch.read_part FOR INSERT TO meesam_worker WITH CHECK (true);
CREATE POLICY read_part_write ON watch.read_part FOR UPDATE TO meesam_worker USING (true) WITH CHECK (true);
GRANT SELECT ON watch.read_run, watch.read_part TO meesam_staff, meesam_admin;
GRANT SELECT, UPDATE ON watch.read_run TO meesam_worker;
GRANT SELECT, INSERT, UPDATE ON watch.read_part TO meesam_worker;

-- Staff read the published marks in the Operations Console (the reviewer's queue follows in the next migration).
CREATE POLICY published_mark_staff_read ON watch.published_mark FOR SELECT TO meesam_staff, meesam_admin USING (true);
GRANT SELECT ON watch.published_mark TO meesam_staff, meesam_admin;

-- The lead asks for a whole issue to be read.
CREATE FUNCTION watch.fn_read_run_request(p_issue_id uuid, p_model text, p_token_cap bigint DEFAULT 3000000) RETURNS uuid
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
  -- the registry's layout must be entered: without it the issue cannot be cut into its entries
  IF i.marker IS NULL THEN RAISE EXCEPTION 'the layout of this registry''s bulletin is not entered yet' USING ERRCODE = '55000'; END IF;
  -- a published mark is stored under its publication date
  IF i.published_on IS NULL THEN RAISE EXCEPTION 'the issue has no publication date' USING ERRCODE = '22004'; END IF;
  IF EXISTS (SELECT 1 FROM watch.read_run r WHERE r.issue_id = p_issue_id AND r.status IN ('queued', 'reading')) THEN
    RAISE EXCEPTION 'this issue is already being read' USING ERRCODE = '23505';
  END IF;
  IF (SELECT count(*) FROM watch.read_run WHERE created_at > now() - interval '24 hours') >= 6 THEN
    RAISE EXCEPTION 'too many full readings in the last day' USING ERRCODE = '54000';
  END IF;
  INSERT INTO watch.read_run (issue_id, model, requested_by, token_cap)
  VALUES (p_issue_id, v_model, platform.current_user_id(), least(20000000, greatest(100000, COALESCE(p_token_cap, 3000000))))
  RETURNING id INTO v_id;
  PERFORM platform.enqueue_job('watch.read_run', jsonb_build_object('id', v_id, 'step', 0), now(), 'watch.read_run:' || v_id || ':0');
  RETURN v_id;
END $$;

-- The lead stops a run: the worker ends it before its next request. What was read so far stays, waiting for verification.
CREATE FUNCTION watch.fn_read_run_stop(p_run_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  UPDATE watch.read_run SET status = 'stopped', error = 'Stopped by the watch operations lead.', finished_at = now(), updated_at = now()
   WHERE id = p_run_id AND status IN ('queued', 'reading');
  IF NOT FOUND THEN RAISE EXCEPTION 'no such running reading' USING ERRCODE = 'P0002'; END IF;
END $$;

-- One mark read by a run is stored among the published marks, waiting for verification.
-- The same mark read again (the same application number in the same issue; without a number, the same page) is
-- brought up to date while it is still unverified; a mark a person has verified is never touched by a reading.
CREATE FUNCTION watch.fn_read_mark_store(p_run_id uuid, p_mark jsonb) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, public, pg_temp AS $$
DECLARE r record; m watch.published_mark; v_no text := NULLIF(btrim(left(p_mark ->> 'application_no', 60)), '');
        v_page text := p_mark ->> 'page'; v_text jsonb; v_classes smallint[]; v_country text; v_extraction jsonb;
BEGIN
  SELECT u.id, u.model, i.id AS issue_id, i.published_on, s.registry_id INTO r
    FROM watch.read_run u JOIN watch.publication_issue i ON i.id = u.issue_id JOIN watch.publication_source s ON s.id = i.source_id
   WHERE u.id = p_run_id;
  IF r.id IS NULL THEN RAISE EXCEPTION 'no such reading' USING ERRCODE = 'P0002'; END IF;
  v_text := jsonb_strip_nulls(jsonb_build_object('ar', NULLIF(btrim(left(p_mark ->> 'mark_text_ar', 300)), ''), 'en', NULLIF(btrim(left(p_mark ->> 'mark_text_en', 300)), '')));
  IF v_text = '{}'::jsonb THEN v_text := NULL; END IF;
  SELECT COALESCE(array_agg(DISTINCT c::smallint ORDER BY c::smallint), '{}') INTO v_classes
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_mark -> 'classes') = 'array' THEN p_mark -> 'classes' ELSE '[]'::jsonb END) c
   WHERE c ~ '^\d{1,2}$' AND c::int BETWEEN 1 AND 45;
  v_country := upper(btrim(p_mark ->> 'applicant_country'));
  IF v_country IS NULL OR v_country !~ '^[A-Z]{2}$' THEN v_country := NULL; END IF;
  -- everything else the reader gave stays beside the mark as read, with the run and the model that read it
  v_extraction := (p_mark - ARRAY['application_no', 'mark_text_ar', 'mark_text_en', 'classes', 'applicant_name', 'applicant_country', 'agent_name'])
                  || jsonb_build_object('run_id', p_run_id, 'model', r.model);

  SELECT * INTO m FROM watch.published_mark x
   WHERE x.registry_id = r.registry_id AND x.publication_date = r.published_on AND x.issue_id = r.issue_id
     AND CASE WHEN v_no IS NOT NULL THEN core.fn_number_key(x.application_no) = core.fn_number_key(v_no)
              ELSE x.application_no IS NULL AND x.extraction ->> 'page' IS NOT DISTINCT FROM v_page END
   LIMIT 1;
  IF m.id IS NOT NULL AND m.verify_state <> 'ai_extracted' THEN RETURN 'kept'; END IF;
  IF m.id IS NOT NULL THEN
    UPDATE watch.published_mark SET application_no = v_no, mark_text = v_text, classes = v_classes,
           applicant_name = NULLIF(btrim(left(p_mark ->> 'applicant_name', 400)), ''), applicant_country = v_country,
           agent_name = NULLIF(btrim(left(p_mark ->> 'agent_name', 400)), ''), extraction = v_extraction, updated_at = now()
     WHERE registry_id = m.registry_id AND publication_date = m.publication_date AND id = m.id;
    RETURN 'updated';
  END IF;
  INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, mark_text, classes, applicant_name, applicant_country, agent_name, extraction)
  VALUES (r.issue_id, r.registry_id, r.published_on, v_no, v_text, v_classes, NULLIF(btrim(left(p_mark ->> 'applicant_name', 400)), ''), v_country,
          NULLIF(btrim(left(p_mark ->> 'agent_name', 400)), ''), v_extraction);
  RETURN 'inserted';
END $$;

-- The comparison of what a run read with the registry's own index and with the file: which numbers the index
-- lists that were not read, which were read that the index does not list, where the class differs, which pages
-- could not be read, and how many entry pages the file's text shows.
CREATE FUNCTION watch.fn_read_run_outcome(p_run_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, core, public, pg_temp AS $$
  WITH run AS (SELECT u.id, u.issue_id, u.entries_found FROM watch.read_run u WHERE u.id = p_run_id),
  idx AS (
    SELECT DISTINCT ON (core.fn_number_key(x ->> 'application_no')) core.fn_number_key(x ->> 'application_no') AS k, x ->> 'application_no' AS no,
           CASE WHEN x ->> 'class' ~ '^\d{1,2}$' THEN (x ->> 'class')::int END AS class, x ->> 'page' AS page
      FROM watch.read_part p, jsonb_array_elements(CASE WHEN jsonb_typeof(p.result -> 'rows') = 'array' THEN p.result -> 'rows' ELSE '[]'::jsonb END) x
     WHERE p.run_id = p_run_id AND p.kind = 'index' AND p.status = 'done' AND core.fn_number_key(x ->> 'application_no') IS NOT NULL
     ORDER BY core.fn_number_key(x ->> 'application_no')),
  got AS (
    SELECT core.fn_number_key(m.application_no) AS k, m.application_no AS no, m.classes, m.extraction ->> 'page' AS page
      FROM watch.published_mark m JOIN run ON m.issue_id = run.issue_id
     WHERE m.extraction ->> 'run_id' = p_run_id::text)
  SELECT jsonb_build_object(
    'index_read', EXISTS (SELECT 1 FROM watch.read_part p WHERE p.run_id = p_run_id AND p.kind = 'index'),
    'index_rows', (SELECT count(*) FROM idx),
    'marks', (SELECT count(*) FROM got),
    'without_number', (SELECT count(*) FROM got WHERE k IS NULL),
    'entry_pages', (SELECT entries_found FROM run),
    'missing', COALESCE((SELECT jsonb_agg(jsonb_build_object('no', i.no, 'class', i.class, 'page', i.page) ORDER BY i.no)
                           FROM idx i WHERE NOT EXISTS (SELECT 1 FROM got g WHERE g.k = i.k)), '[]'::jsonb),
    'not_in_index', COALESCE((SELECT jsonb_agg(jsonb_build_object('no', g.no, 'page', g.page) ORDER BY g.no)
                                FROM got g WHERE g.k IS NOT NULL AND EXISTS (SELECT 1 FROM idx) AND NOT EXISTS (SELECT 1 FROM idx i WHERE i.k = g.k)), '[]'::jsonb),
    'class_differs', COALESCE((SELECT jsonb_agg(jsonb_build_object('no', g.no, 'index', i.class, 'read', to_jsonb(g.classes)) ORDER BY g.no)
                                 FROM got g JOIN idx i ON i.k = g.k WHERE i.class IS NOT NULL AND NOT (i.class = ANY (g.classes))), '[]'::jsonb),
    'pages_not_read', COALESCE((SELECT jsonb_agg(jsonb_build_object('from', p.from_page, 'to', p.to_page, 'kind', p.kind, 'why', left(p.error, 200)) ORDER BY p.seq)
                                  FROM watch.read_part p WHERE p.run_id = p_run_id AND p.status <> 'done'), '[]'::jsonb))
$$;

REVOKE EXECUTE ON FUNCTION watch.fn_read_run_request(uuid, text, bigint), watch.fn_read_run_stop(uuid), watch.fn_read_mark_store(uuid, jsonb), watch.fn_read_run_outcome(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_read_run_request(uuid, text, bigint), watch.fn_read_run_stop(uuid) TO meesam_staff, meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_read_mark_store(uuid, jsonb) TO meesam_worker;
GRANT EXECUTE ON FUNCTION watch.fn_read_run_outcome(uuid) TO meesam_worker, meesam_staff, meesam_admin;

-- Qatar: every entry begins with "قدم عنها الطلب رقم" (the pattern that finds where to cut; the wider entry_marker
-- of 0065 also matches the applicant line, which a long entry prints on a later page), and an index is printed
-- before the entries (number, class, page): it is read and compared.
UPDATE watch.publication_source s
   SET fetch_spec = jsonb_set(jsonb_set(s.fetch_spec, '{read,index}', '"before_entries"'), '{read,entry_start}', to_jsonb('قدم عنها الطلب رقم'::text))
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'QA' AND s.stream = 'national_bulletin' AND s.fetch_spec ? 'read';

COMMIT;
