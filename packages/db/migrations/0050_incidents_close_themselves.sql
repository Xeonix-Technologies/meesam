-- 0050 — An incident closes by itself when its source works again (Founder, staging test 20 Nov 2026: Qatar's
-- gazette had been fetched, yet the source still showed "Failing" because its incident waited to be closed by
-- hand). A fetched issue closes the source's open incident with a note; so does handing the source to
-- collection by hand. Incidents already overtaken by a later success are closed now. The lead can still close
-- one by hand.
BEGIN;

UPDATE watch.fetch_incident x
   SET closed_at = now(), close_note = 'Closed automatically: an issue was fetched after this incident opened.', updated_at = now()
  FROM watch.publication_source s
 WHERE s.id = x.source_id AND x.closed_at IS NULL AND s.last_success_at > x.opened_at AND s.failures = 0;
UPDATE watch.fetch_incident x
   SET closed_at = now(), close_note = 'Closed automatically: the source is collected by hand for now.', updated_at = now()
  FROM watch.publication_source s
 WHERE s.id = x.source_id AND x.closed_at IS NULL AND s.manual_intake;

CREATE OR REPLACE FUNCTION watch.fn_fetch_stored(p_source_id uuid, p_issue_no text, p_published date, p_url text, p_title text,
                                      p_object_key text, p_sha256 bytea, p_bytes bigint, p_container text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
DECLARE v_id uuid; v_prev watch.publication_issue; v_again boolean := false;
BEGIN
  IF EXISTS (SELECT 1 FROM watch.publication_issue WHERE sha256 = p_sha256) THEN
    INSERT INTO watch.fetch_run (source_id, finished_at, outcome, detail)
    VALUES (p_source_id, now(), 'fetched', jsonb_build_object('issue_no', p_issue_no, 'duplicate', true, 'url', p_url));
    -- remember the number so the same link is not downloaded again on every poll
    INSERT INTO watch.publication_issue (source_id, issue_no, published_on, source_url, title, fetch_status, recovery_log)
    VALUES (p_source_id, p_issue_no, p_published, p_url, p_title, 'fetched', jsonb_build_array(jsonb_build_object('at', now(), 'step', 'duplicate', 'note', 'same file as an issue already held')))
    ON CONFLICT (source_id, issue_no) DO NOTHING;
    RETURN NULL;
  END IF;
  SELECT * INTO v_prev FROM watch.publication_issue WHERE source_id = p_source_id AND issue_no = p_issue_no FOR UPDATE;
  v_again := v_prev.id IS NOT NULL;
  IF v_again THEN
    UPDATE watch.publication_issue
       SET published_on = COALESCE(p_published, published_on), fetched_at = now(), object_key = p_object_key, sha256 = p_sha256,
           size_bytes = p_bytes, container = p_container, source_url = p_url, title = p_title, fetch_status = 'retried', updated_at = now(),
           recovery_log = recovery_log || jsonb_build_object('at', now(), 'step', 'retry', 'outcome', 'recovered')
     WHERE id = v_prev.id RETURNING id INTO v_id;
  ELSE
    INSERT INTO watch.publication_issue (source_id, issue_no, published_on, fetched_at, object_key, sha256, size_bytes, container, source_url, title, fetch_status)
    VALUES (p_source_id, p_issue_no, p_published, now(), p_object_key, p_sha256, p_bytes, p_container, p_url, p_title, 'fetched') RETURNING id INTO v_id;
  END IF;
  INSERT INTO watch.fetch_run (source_id, issue_id, finished_at, outcome, attempt, detail)
  VALUES (p_source_id, v_id, now(), CASE WHEN v_again THEN 'recovered' ELSE 'fetched' END::watch.fetch_outcome,
          CASE WHEN v_again THEN 1 + (SELECT count(*) FROM watch.fetch_run r WHERE r.issue_id = v_prev.id) ELSE 1 END,
          jsonb_build_object('issue_no', p_issue_no, 'bytes', p_bytes, 'url', p_url));
  UPDATE watch.publication_source SET failures = 0, last_success_at = now(), updated_at = now() WHERE id = p_source_id;
  -- the source works again: its open incident closes by itself, with a note saying so
  UPDATE watch.fetch_incident SET closed_at = now(), close_note = 'Closed automatically: an issue was fetched, the source works again.', updated_at = now()
   WHERE source_id = p_source_id AND closed_at IS NULL;
  -- the next expected release, from the stream's rhythm (a hint for lateness, never a deadline)
  UPDATE watch.publication_schedule c
     SET expected_next = GREATEST(COALESCE(c.expected_next, p_published), p_published + CASE c.frequency WHEN 'weekly' THEN 7 WHEN 'fortnightly' THEN 14 WHEN 'monthly' THEN 30 END),
         updated_at = now()
   WHERE c.source_id = p_source_id AND p_published IS NOT NULL AND c.frequency <> 'irregular';
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION watch.fn_source_manual(p_source_id uuid, p_on boolean, p_reason text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_reason text := NULLIF(btrim(left(p_reason, 300)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF p_on AND v_reason IS NULL THEN RAISE EXCEPTION 'the reason is required' USING ERRCODE = '22023'; END IF;
  UPDATE watch.publication_source
     SET manual_intake = p_on,
         manual_since = CASE WHEN p_on THEN now() END, manual_by = CASE WHEN p_on THEN platform.current_user_id() END,
         manual_reason = CASE WHEN p_on THEN v_reason END, manual_reminded_on = NULL,
         paused = CASE WHEN p_on THEN true ELSE paused END,
         paused_at = CASE WHEN p_on THEN now() ELSE paused_at END,
         paused_by = CASE WHEN p_on THEN platform.current_user_id() ELSE paused_by END,
         pause_note = CASE WHEN p_on THEN 'Collected by hand: ' || v_reason ELSE pause_note END,
         updated_at = now()
   WHERE id = p_source_id AND active;      -- re-use must be confirmed first, as for a fetcher
  IF NOT FOUND THEN RAISE EXCEPTION 'no such source with re-use confirmed' USING ERRCODE = 'P0002'; END IF;
  -- a source handed to collection by hand is no longer a broken fetcher to chase: its open incident closes
  IF p_on THEN
    UPDATE watch.fetch_incident SET closed_at = now(), closed_by = platform.current_user_id(), close_note = 'Closed: the source is collected by hand for now. ' || v_reason, updated_at = now()
     WHERE source_id = p_source_id AND closed_at IS NULL;
  END IF;
END $$;

COMMIT;
