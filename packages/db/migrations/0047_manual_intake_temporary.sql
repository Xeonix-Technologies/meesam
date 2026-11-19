-- 0047 — Temporary collection by hand (Founder ruling 19 Nov 2026).
-- Until now no publication could ever be uploaded by a person (ruled 7–8 Nov 2026; CLAUDE.md rule 7). The Founder
-- ruled a temporary exception after the UK and Bahrain sites refused Meesam's fetcher: for a source the watch
-- operations lead has switched to "by hand", the staff are reminded when an issue is due, download it from the
-- registry themselves and add it in the console; it enters the same inbox as a fetched issue.
-- Kept narrow: per source, switched on with a stated reason and switched off again; the file passes the same
-- shape check and is stored once by checksum; who added it is recorded and audited. A source not switched to
-- "by hand" still takes no file from anyone.
BEGIN;

ALTER TABLE watch.publication_source
  ADD COLUMN manual_intake      boolean NOT NULL DEFAULT false,
  ADD COLUMN manual_since       timestamptz NULL,
  ADD COLUMN manual_by          uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN manual_reason      text NULL,
  ADD COLUMN manual_reminded_on date NULL;

ALTER TABLE watch.publication_issue
  ADD COLUMN intake    text NOT NULL DEFAULT 'fetched' CHECK (intake IN ('fetched', 'manual')),
  ADD COLUMN added_by  uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN file_name text NULL;
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.publication_issue
  FOR EACH ROW WHEN (platform.current_user_id() IS NOT NULL) EXECUTE FUNCTION platform.trg_audit_row();

-- Switch a source to collection by hand, or back. On: the reason is required and the automatic fetcher is paused
-- (it has been refused; it should stop asking). Off: the fetcher stays paused until the lead resumes it.
CREATE FUNCTION watch.fn_source_manual(p_source_id uuid, p_on boolean, p_reason text DEFAULT NULL) RETURNS void
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
END $$;

-- When is the next issue of a by-hand source due? The expected release where one is known; otherwise a week
-- after the last issue was added; at once when nothing is held yet.
CREATE FUNCTION watch.fn_manual_due_on(p_source_id uuid) RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
  SELECT COALESCE(
           (SELECT c.expected_next FROM watch.publication_schedule c WHERE c.source_id = s.id),
           (SELECT (max(i.fetched_at) + interval '7 days')::date FROM watch.publication_issue i WHERE i.source_id = s.id AND i.object_key IS NOT NULL),
           s.manual_since::date)
    FROM watch.publication_source s WHERE s.id = p_source_id AND s.manual_intake
$$;

-- A file a staff member downloaded from the registry and added in the console. Same rules as a fetched file:
-- one issue number per source, one copy of a file by checksum. The issue date is required (the person can read
-- it in the publication) and cannot be in the future.
CREATE FUNCTION watch.fn_manual_add(p_source_id uuid, p_issue_no text, p_published date, p_object_key text, p_sha256 bytea,
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
  SELECT * INTO v_prev FROM watch.publication_issue WHERE source_id = p_source_id AND issue_no = v_no FOR UPDATE;
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

-- The reminders the worker sends: one row per by-hand source that is due and per watch operations lead, at most
-- once every three days while it stays due. Taking them marks them sent.
CREATE FUNCTION watch.fn_manual_reminders_take()
RETURNS TABLE (source_id uuid, registry_code text, registry_name jsonb, stream text, due_on date, last_issue text, where_from text, email text, name text, locale text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, platform, core, public, pg_temp AS $$
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT s.id, watch.fn_manual_due_on(s.id) AS due_on FROM watch.publication_source s
     WHERE s.active AND s.manual_intake AND (s.manual_reminded_on IS NULL OR s.manual_reminded_on <= current_date - 3)
  ), marked AS (
    UPDATE watch.publication_source s SET manual_reminded_on = current_date FROM due d WHERE d.id = s.id AND d.due_on <= current_date RETURNING s.id, d.due_on
  )
  SELECT m.id, g.code::text, g.name, s.stream::text, m.due_on,
         (SELECT i.issue_no FROM watch.publication_issue i WHERE i.source_id = m.id AND i.object_key IS NOT NULL ORDER BY i.fetched_at DESC LIMIT 1),
         COALESCE(s.fetch_spec ->> 'manual_page', s.fetch_spec ->> 'url', s.fetch_spec ->> 'where'),
         u.email::text, u.name, u.locale::text
    FROM marked m
    JOIN watch.publication_source s ON s.id = m.id
    JOIN registry.registry g ON g.id = s.registry_id
    JOIN platform.staff_role r ON r.role = 'watch_lead'
    JOIN core.app_user u ON u.id = r.user_id AND u.status = 'active';
END $$;

REVOKE EXECUTE ON FUNCTION watch.fn_source_manual(uuid, boolean, text), watch.fn_manual_due_on(uuid),
  watch.fn_manual_add(uuid, text, date, text, bytea, bigint, text, text), watch.fn_manual_reminders_take() FROM PUBLIC, meesam_app, meesam_staff, meesam_worker;
GRANT EXECUTE ON FUNCTION watch.fn_source_manual(uuid, boolean, text), watch.fn_manual_add(uuid, text, date, text, bytea, bigint, text, text) TO meesam_staff, meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_manual_due_on(uuid) TO meesam_staff, meesam_admin, meesam_worker;
GRANT EXECUTE ON FUNCTION watch.fn_manual_reminders_take() TO meesam_worker, meesam_admin;

-- where a person finds each publication (the pages a browser can open)
UPDATE watch.publication_source ps SET fetch_spec = ps.fetch_spec || jsonb_build_object('manual_page', 'https://www.ipo.gov.uk/t-tmj.htm')
  FROM registry.registry g WHERE g.id = ps.registry_id AND g.code = 'GB' AND ps.stream = 'national_bulletin';
UPDATE watch.publication_source ps SET fetch_spec = ps.fetch_spec || jsonb_build_object('manual_page', 'https://www.moic.gov.bh/en/node/2817')
  FROM registry.registry g WHERE g.id = ps.registry_id AND g.code = 'BH' AND ps.stream = 'national_bulletin';

COMMIT;
