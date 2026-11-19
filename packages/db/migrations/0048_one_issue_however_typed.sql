-- 0048 — One issue, however its number is typed (Founder, staging test 19 Nov 2026: the UK journal added by hand
-- as "2026/046" appeared beside the fetcher's failed attempt "2026-046" as a second issue).
-- An issue number is compared by its letters and digits only; a number typed by hand takes the form already on
-- record, or is written with hyphens. Rows already split this way are joined: the held file keeps the number the
-- fetcher uses, and the attempts logged against the other row move to it.
BEGIN;

CREATE FUNCTION watch.fn_issue_key(p_issue_no text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT lower(regexp_replace(COALESCE(p_issue_no, ''), '[^A-Za-z0-9]', '', 'g')) $$;
GRANT EXECUTE ON FUNCTION watch.fn_issue_key(text) TO meesam_staff, meesam_admin, meesam_worker;

-- join the rows already split: h = the row holding the file, f = the row without one (a failed attempt)
CREATE TEMP TABLE _pair ON COMMIT DROP AS
SELECT h.id AS held, f.id AS empty, f.issue_no AS keep_no
  FROM watch.publication_issue h
  JOIN watch.publication_issue f ON f.source_id = h.source_id AND f.id <> h.id AND f.object_key IS NULL
                                AND watch.fn_issue_key(f.issue_no) = watch.fn_issue_key(h.issue_no)
 WHERE h.object_key IS NOT NULL;
UPDATE watch.fetch_run r SET issue_id = p.held FROM _pair p WHERE r.issue_id = p.empty;
UPDATE watch.publication_issue h
   SET recovery_log = f.recovery_log || h.recovery_log, source_url = COALESCE(h.source_url, f.source_url), updated_at = now()
  FROM _pair p JOIN watch.publication_issue f ON f.id = p.empty WHERE h.id = p.held;
DELETE FROM watch.publication_issue f USING _pair p WHERE f.id = p.empty;
UPDATE watch.publication_issue h SET issue_no = p.keep_no FROM _pair p WHERE h.id = p.held;

CREATE OR REPLACE FUNCTION watch.fn_manual_add(p_source_id uuid, p_issue_no text, p_published date, p_object_key text, p_sha256 bytea,
                                    p_bytes bigint, p_container text, p_file_name text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_no text := NULLIF(btrim(left(p_issue_no, 80)), ''); v_prev watch.publication_issue; v_me uuid := platform.current_user_id();
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM watch.publication_source WHERE id = p_source_id AND active AND manual_intake) THEN
    RAISE EXCEPTION 'this source is not collected by hand' USING ERRCODE = '42501';
  END IF;
  IF v_no IS NULL OR p_published IS NULL THEN RAISE EXCEPTION 'issue number and issue date are required' USING ERRCODE = '22023'; END IF;
  IF p_published > current_date + 1 THEN RAISE EXCEPTION 'the issue date is in the future' USING ERRCODE = '22008'; END IF;
  IF EXISTS (SELECT 1 FROM watch.publication_issue WHERE sha256 = p_sha256) THEN
    RAISE EXCEPTION 'this file is already held' USING ERRCODE = 'unique_violation';
  END IF;
  -- the same issue however its number is typed: 2026/046, 2026 046 and 2026-046 are one issue, and the number
  -- already on record (from the fetcher's attempt or an earlier entry) is the one kept
  SELECT * INTO v_prev FROM watch.publication_issue
   WHERE source_id = p_source_id AND watch.fn_issue_key(issue_no) = watch.fn_issue_key(v_no)
   ORDER BY (object_key IS NOT NULL) DESC, created_at LIMIT 1 FOR UPDATE;
  v_no := COALESCE(v_prev.issue_no, regexp_replace(v_no, '\s*[/\\_]\s*|\s+-\s+', '-', 'g'));
  IF v_prev.object_key IS NOT NULL THEN RAISE EXCEPTION 'this issue is already held' USING ERRCODE = 'unique_violation'; END IF;
  IF v_prev.id IS NOT NULL THEN
    UPDATE watch.publication_issue
       SET published_on = p_published, fetched_at = now(), object_key = p_object_key, sha256 = p_sha256, size_bytes = p_bytes, container = p_container,
           file_name = left(p_file_name, 200), intake = 'manual', added_by = v_me, fetch_status = 'retried', updated_at = now(),
           recovery_log = recovery_log || jsonb_build_object('at', now(), 'step', 'manual', 'outcome', 'added by hand')
     WHERE id = v_prev.id RETURNING id INTO v_id;
  ELSE
    INSERT INTO watch.publication_issue (source_id, issue_no, published_on, fetched_at, object_key, sha256, size_bytes, container, file_name, intake, added_by, fetch_status, title)
    VALUES (p_source_id, v_no, p_published, now(), p_object_key, p_sha256, p_bytes, p_container, left(p_file_name, 200), 'manual', v_me, 'fetched', left(p_file_name, 200))
    RETURNING id INTO v_id;
  END IF;
  INSERT INTO watch.fetch_run (source_id, issue_id, finished_at, outcome, detail)
  VALUES (p_source_id, v_id, now(), CASE WHEN v_prev.id IS NOT NULL THEN 'recovered' ELSE 'fetched' END::watch.fetch_outcome,
          jsonb_build_object('issue_no', v_no, 'bytes', p_bytes, 'manual', true, 'by', (SELECT name FROM core.app_user WHERE id = v_me)));
  UPDATE watch.publication_source SET last_success_at = now(), manual_reminded_on = NULL, updated_at = now() WHERE id = p_source_id;
  UPDATE watch.publication_schedule c
     SET expected_next = GREATEST(COALESCE(c.expected_next, p_published), p_published + CASE c.frequency WHEN 'weekly' THEN 7 WHEN 'fortnightly' THEN 14 WHEN 'monthly' THEN 30 END),
         updated_at = now()
   WHERE c.source_id = p_source_id AND c.frequency <> 'irregular';
  RETURN v_id;
END $$;

COMMIT;
