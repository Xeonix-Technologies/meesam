-- 0041 — Watch, stage 1: Fetch (MSM-PRD-02 Section 3 stage 1, Section 4; Operations Console Section 9A).
-- The worker polls each active source from its catalogue row, downloads the issues whose opposition window is
-- still open, checks and stores each file once (by checksum) and logs every attempt. A failed download is
-- retried with backoff; after three failures in a row a "source broken" incident is opened for the staff.
-- No manual upload exists anywhere (CLAUDE.md rule 7): staff can pause, resume, ask for a poll and close an
-- incident; they never carry a file.
BEGIN;

ALTER TABLE watch.publication_source
  ADD COLUMN paused          boolean NOT NULL DEFAULT false,
  ADD COLUMN paused_at       timestamptz NULL,
  ADD COLUMN paused_by       uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN pause_note      text NULL,
  ADD COLUMN first_polled_at timestamptz NULL,
  ADD COLUMN last_polled_at  timestamptz NULL,
  ADD COLUMN last_success_at timestamptz NULL,
  ADD COLUMN next_poll_at    timestamptz NULL,
  ADD COLUMN failures        integer NOT NULL DEFAULT 0;

ALTER TABLE watch.publication_issue
  ADD COLUMN source_url text NULL,
  ADD COLUMN title      text NULL,
  ADD COLUMN size_bytes bigint NULL,
  ADD COLUMN container  text NULL;        -- what the stored file is: rar, zip, pdf, xml, …

CREATE TABLE watch.fetch_incident (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id           uuid NOT NULL REFERENCES watch.publication_source(id),
  kind                text NOT NULL DEFAULT 'source_broken' CHECK (kind IN ('source_broken')),
  opened_at           timestamptz NOT NULL DEFAULT now(),
  detail              jsonb NOT NULL DEFAULT '{}'::jsonb,
  earliest_window_end date NULL,           -- the first opposition window at risk, when it can be computed
  closed_at           timestamptz NULL,
  closed_by           uuid NULL REFERENCES core.app_user(id),
  close_note          text NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX fetch_incident_one_open ON watch.fetch_incident (source_id) WHERE closed_at IS NULL;
GRANT SELECT, INSERT, UPDATE, DELETE ON watch.fetch_incident TO meesam_worker, meesam_admin;
GRANT SELECT ON watch.fetch_incident TO meesam_staff, meesam_readonly;
-- staff change sources and incidents only through the functions below
REVOKE INSERT, UPDATE ON watch.publication_source, watch.publication_issue, watch.fetch_run FROM meesam_staff;

-- every staff action on these is audited (Section 9A "Audit")
-- (the worker's hourly bookkeeping on a source carries no user and is not an audit event)
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.publication_source FOR EACH ROW WHEN (platform.current_user_id() IS NOT NULL) EXECUTE FUNCTION platform.trg_audit_row();
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.fetch_incident FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row();

-- The UAE catalogue row as observed on 19 Nov 2026: MoET lists every issue on its publications page as ONE
-- archive (.rar) per issue, newest first, with the issue number and date in the link text. The archive holds the
-- PDFs of the issue (national types and the Madrid APP Publication), so the Madrid stream is read from the same
-- file and is not downloaded on its own. All of this is data: a moved page is a catalogue fix, not a release.
UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object(
         'url', 'https://www.moet.gov.ae/en/-/trademark-bulletin-no-235?delta=60',
         'link_href', '\.rar(/|$|\?)',
         'issue_no', 'Bulletin\s+No\.?\s*(\d+)',
         'date', '(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})',
         'container', 'rar',
         'poll_minutes', 60,
         'max_per_run', 3,
         'observed', '19 Nov 2026: one .rar archive per issue on the MoET publications page')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'AE' AND ps.stream = 'national_bulletin';
UPDATE watch.publication_source ps
   SET fetch_spec = ps.fetch_spec || jsonb_build_object('inside', 'national_bulletin')
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'AE' AND ps.stream = 'madrid_designations';

-- The opposition period of a source's registry, from the registry profile and only when verified (rule 4).
CREATE FUNCTION watch.fn_source_window(p_source_id uuid, OUT days integer, OUT timezone text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
  SELECT CASE WHEN COALESCE((p.rules #>> '{timers,oppose,verified}')::boolean, false) THEN (p.rules #>> '{timers,oppose,days}')::integer END,
         COALESCE(p.rules #>> '{calendar,timezone}', 'UTC')
    FROM watch.publication_source s, LATERAL registry.fn_current_profile(s.registry_id) p
   WHERE s.id = p_source_id
$$;

-- Is an issue of that date to be downloaded? Yes while its opposition window is open (the last day ends 23:59
-- registry time). Where the period is unverified no window can be computed: only issues published since the
-- source was first polled are taken. An issue with no readable date is taken, so nothing is silently skipped.
CREATE FUNCTION watch.fn_fetch_wanted(p_source_id uuid, p_published date) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
DECLARE w record; first timestamptz;
BEGIN
  IF p_published IS NULL THEN RETURN true; END IF;
  SELECT * INTO w FROM watch.fn_source_window(p_source_id);
  IF w.days IS NOT NULL THEN RETURN core.fn_due_at(p_published + w.days, w.timezone) >= now(); END IF;
  SELECT first_polled_at INTO first FROM watch.publication_source WHERE id = p_source_id;
  RETURN p_published >= COALESCE(first, now())::date;
END $$;

-- Sources the worker should poll now: re-use confirmed (active), not paused, with a location in the catalogue.
CREATE FUNCTION watch.fn_fetch_due()
RETURNS TABLE (source_id uuid, registry_code text, stream text, format text, fetch_spec jsonb, failures integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
  SELECT s.id, g.code::text, s.stream::text, s.format::text, s.fetch_spec, s.failures
    FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id
   WHERE s.active AND NOT s.paused AND s.fetch_spec ? 'url' AND (s.next_poll_at IS NULL OR s.next_poll_at <= now())
   ORDER BY s.next_poll_at NULLS FIRST
$$;

-- What is already held for a source: stored issues are skipped, failed ones are tried again.
CREATE FUNCTION watch.fn_fetch_known(p_source_id uuid) RETURNS TABLE (issue_no text, stored boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
  SELECT i.issue_no, i.fetch_status <> 'failed' FROM watch.publication_issue i WHERE i.source_id = p_source_id
$$;

-- A poll that read the page: remembers when, sets the next poll, and notes a late release when one was expected.
CREATE FUNCTION watch.fn_fetch_polled(p_source_id uuid, p_listed integer, p_new integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
DECLARE s watch.publication_source; late boolean;
BEGIN
  SELECT * INTO s FROM watch.publication_source WHERE id = p_source_id FOR UPDATE;
  UPDATE watch.publication_source
     SET first_polled_at = COALESCE(first_polled_at, now()), last_polled_at = now(), updated_at = now(),
         next_poll_at = now() + make_interval(mins => GREATEST(COALESCE((fetch_spec ->> 'poll_minutes')::integer, 60), 15))
   WHERE id = p_source_id;
  SELECT c.expected_next < current_date INTO late FROM watch.publication_schedule c WHERE c.source_id = p_source_id;
  IF p_new = 0 AND COALESCE(late, false) AND NOT EXISTS (
       SELECT 1 FROM watch.fetch_run r WHERE r.source_id = p_source_id AND r.outcome = 'not_yet_published' AND r.started_at > now() - interval '23 hours') THEN
    INSERT INTO watch.fetch_run (source_id, finished_at, outcome, detail)
    VALUES (p_source_id, now(), 'not_yet_published', jsonb_build_object('listed', p_listed));
  END IF;
END $$;

-- A file that passed the shape check and is in the bucket. A file already held (same checksum) is not stored
-- twice: the call returns NULL and the run says why. Success clears the failure count and closes nothing by
-- itself: an open incident is closed by the staff, who see that the source works again.
CREATE FUNCTION watch.fn_fetch_stored(p_source_id uuid, p_issue_no text, p_published date, p_url text, p_title text,
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
  -- the next expected release, from the stream's rhythm (a hint for lateness, never a deadline)
  UPDATE watch.publication_schedule c
     SET expected_next = GREATEST(COALESCE(c.expected_next, p_published), p_published + CASE c.frequency WHEN 'weekly' THEN 7 WHEN 'fortnightly' THEN 14 WHEN 'monthly' THEN 30 END),
         updated_at = now()
   WHERE c.source_id = p_source_id AND p_published IS NOT NULL AND c.frequency <> 'irregular';
  RETURN v_id;
END $$;

-- A failed step (reading the page, downloading, the shape check, storing). Recovery step 1 of Section 4: retry
-- with backoff inside the hour (5, 15, 30 minutes). After three failures in a row the source is "failing" and a
-- "source broken" incident is opened, with the earliest opposition window at risk. Returns the failure count.
-- RULING NEEDED: recovery steps 2 to 4 (other fetcher types, AI re-discovery, secondary sources) are not built yet.
CREATE FUNCTION watch.fn_fetch_failed(p_source_id uuid, p_issue_no text, p_published date, p_url text, p_step text, p_error text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
DECLARE v_issue uuid; v_fail integer; w record; v_end date;
BEGIN
  IF p_issue_no IS NOT NULL THEN
    INSERT INTO watch.publication_issue (source_id, issue_no, published_on, source_url, fetch_status, recovery_log)
    VALUES (p_source_id, p_issue_no, p_published, p_url, 'failed', jsonb_build_array(jsonb_build_object('at', now(), 'step', p_step, 'error', left(p_error, 500))))
    ON CONFLICT (source_id, issue_no) DO UPDATE
      SET recovery_log = watch.publication_issue.recovery_log || jsonb_build_object('at', now(), 'step', p_step, 'error', left(p_error, 500)), updated_at = now()
    RETURNING id INTO v_issue;
  END IF;
  UPDATE watch.publication_source
     SET failures = failures + 1, last_polled_at = now(), first_polled_at = COALESCE(first_polled_at, now()), updated_at = now(),
         next_poll_at = now() + CASE failures WHEN 0 THEN interval '5 minutes' WHEN 1 THEN interval '15 minutes' WHEN 2 THEN interval '30 minutes' ELSE interval '60 minutes' END
   WHERE id = p_source_id RETURNING failures INTO v_fail;
  INSERT INTO watch.fetch_run (source_id, issue_id, finished_at, outcome, attempt, detail)
  VALUES (p_source_id, v_issue, now(), 'failed', v_fail, jsonb_build_object('issue_no', p_issue_no, 'step', p_step, 'error', left(p_error, 500), 'url', p_url));
  IF v_fail >= 3 AND NOT EXISTS (SELECT 1 FROM watch.fetch_incident WHERE source_id = p_source_id AND closed_at IS NULL) THEN
    SELECT * INTO w FROM watch.fn_source_window(p_source_id);
    IF w.days IS NOT NULL THEN
      -- the oldest publication that could not be downloaded and whose window is still open
      SELECT min(i.published_on) + w.days INTO v_end FROM watch.publication_issue i
       WHERE i.source_id = p_source_id AND i.fetch_status = 'failed' AND i.published_on IS NOT NULL AND i.published_on + w.days >= current_date;
    END IF;
    INSERT INTO watch.fetch_incident (source_id, detail, earliest_window_end)
    VALUES (p_source_id, jsonb_build_object('step', p_step, 'error', left(p_error, 500), 'failures', v_fail, 'issue_no', p_issue_no), v_end);
  END IF;
  RETURN v_fail;
END $$;

REVOKE EXECUTE ON FUNCTION watch.fn_fetch_due(), watch.fn_fetch_known(uuid), watch.fn_fetch_polled(uuid, integer, integer),
  watch.fn_fetch_stored(uuid, text, date, text, text, text, bytea, bigint, text), watch.fn_fetch_failed(uuid, text, date, text, text, text),
  watch.fn_fetch_wanted(uuid, date), watch.fn_source_window(uuid) FROM PUBLIC, meesam_app, meesam_staff;
GRANT EXECUTE ON FUNCTION watch.fn_fetch_due(), watch.fn_fetch_known(uuid), watch.fn_fetch_polled(uuid, integer, integer),
  watch.fn_fetch_stored(uuid, text, date, text, text, text, bytea, bigint, text), watch.fn_fetch_failed(uuid, text, date, text, text, text),
  watch.fn_fetch_wanted(uuid, date), watch.fn_source_window(uuid) TO meesam_worker, meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_source_window(uuid) TO meesam_staff;

-- ---- staff actions (Operations Console): the watch operations lead only ----
CREATE FUNCTION watch.fn_is_watch_lead() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM platform.staff_role r WHERE r.user_id = platform.current_user_id() AND r.role = 'watch_lead')
$$;

-- Pause or resume a fetcher. Resuming, like "poll now", makes the next poll due at once.
CREATE FUNCTION watch.fn_source_pause(p_source_id uuid, p_paused boolean, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  UPDATE watch.publication_source
     SET paused = p_paused, paused_at = CASE WHEN p_paused THEN now() END, paused_by = CASE WHEN p_paused THEN platform.current_user_id() END,
         pause_note = CASE WHEN p_paused THEN NULLIF(btrim(left(p_note, 300)), '') END,
         next_poll_at = CASE WHEN p_paused THEN next_poll_at ELSE now() END, updated_at = now()
   WHERE id = p_source_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such active source' USING ERRCODE = 'P0002'; END IF;
END $$;

CREATE FUNCTION watch.fn_source_poll_now(p_source_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  UPDATE watch.publication_source SET next_poll_at = now(), updated_at = now() WHERE id = p_source_id AND active AND NOT paused;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such running source' USING ERRCODE = 'P0002'; END IF;
END $$;

-- Close an incident once the source works again; the failure count starts afresh and a poll is due at once.
CREATE FUNCTION watch.fn_incident_close(p_incident_id uuid, p_note text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
DECLARE v_source uuid;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  UPDATE watch.fetch_incident SET closed_at = now(), closed_by = platform.current_user_id(), close_note = NULLIF(btrim(left(p_note, 500)), ''), updated_at = now()
   WHERE id = p_incident_id AND closed_at IS NULL RETURNING source_id INTO v_source;
  IF v_source IS NULL THEN RAISE EXCEPTION 'no such open incident' USING ERRCODE = 'P0002'; END IF;
  UPDATE watch.publication_source SET failures = 0, next_poll_at = now(), updated_at = now() WHERE id = v_source;
END $$;

REVOKE EXECUTE ON FUNCTION watch.fn_is_watch_lead(), watch.fn_source_pause(uuid, boolean, text), watch.fn_source_poll_now(uuid), watch.fn_incident_close(uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_is_watch_lead(), watch.fn_source_pause(uuid, boolean, text), watch.fn_source_poll_now(uuid), watch.fn_incident_close(uuid, text) TO meesam_staff, meesam_admin;

-- A staff member can hold more than one role (MSM-PRD-02 Section 9A: the System Administrator may be given the
-- lead role). The last System Administrator can never lose that role.
CREATE FUNCTION platform.fn_staff_role_set(p_user_id uuid, p_role text, p_on boolean, p_by uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform.staff_role WHERE user_id = p_user_id) THEN RAISE EXCEPTION 'not a staff member' USING ERRCODE = 'P0002'; END IF;
  IF p_on THEN
    INSERT INTO platform.staff_role (user_id, role, granted_by) VALUES (p_user_id, p_role, p_by) ON CONFLICT (user_id, role) DO NOTHING;
  ELSE
    IF p_role = 'system_admin' AND (SELECT count(*) FROM platform.staff_role r JOIN core.app_user u ON u.id = r.user_id WHERE r.role = 'system_admin' AND u.status = 'active' AND r.user_id <> p_user_id) = 0 THEN
      RAISE EXCEPTION 'the last active System Administrator cannot lose the role' USING ERRCODE = '23514';
    END IF;
    IF (SELECT count(*) FROM platform.staff_role WHERE user_id = p_user_id) <= 1 THEN
      RAISE EXCEPTION 'a staff member keeps at least one role; remove the person instead' USING ERRCODE = '23514';
    END IF;
    DELETE FROM platform.staff_role WHERE user_id = p_user_id AND role = p_role;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION platform.fn_staff_role_set(uuid, text, boolean, uuid) FROM PUBLIC, meesam_app, meesam_staff;
GRANT EXECUTE ON FUNCTION platform.fn_staff_role_set(uuid, text, boolean, uuid) TO meesam_admin;

COMMIT;
