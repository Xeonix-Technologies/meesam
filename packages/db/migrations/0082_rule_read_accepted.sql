-- 0082 — Founder rulings, 22 Nov 2026, after the first full run on staging (Türkiye's bulletin 504: 2,966 pages,
-- 6,691 marks read by rules in 131 seconds, equal to the office's own list):
--  1. "Do marks read by rules need a person? Preferably NO." A mark read from the file's own text that is complete
--     and present in the office's own list of numbers is accepted without a person; an incomplete one still waits in
--     the reviewer's queue. This is a setting on the source (fetch_spec.read.accept), so it is retired per registry,
--     as rule 7 says. Marks read by the AI reader are not touched: they still wait for a person.
--  2. "Alerts should be raised anyway and leave the decision to the owner": an alert is raised also where the
--     opposition period has ended. A trademark added to a registry later is therefore compared with that registry's
--     publications of the last year (a setting, backfill_days), no longer only with those inside the period.
--  3. Names are not re-written in Arabic letters for Arabic readers (stays as built; no change here).
-- A whole issue is compared as one job, not one job per mark.
BEGIN;

-- comparing in bulk: the per-mark job is not queued while a whole issue is being accepted
CREATE OR REPLACE FUNCTION watch.trg_mark_compare() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NEW.verify_state <> 'ai_extracted' AND COALESCE(current_setting('meesam.bulk_compare', true), '') <> 'on' THEN
    PERFORM platform.enqueue_job('watch.compare', jsonb_build_object('registry_id', NEW.registry_id, 'publication_date', NEW.publication_date, 'mark_id', NEW.id), now(), 'watch.compare:' || NEW.id);
  END IF;
  RETURN NULL;
END $$;

-- every verified or accepted mark of an issue against the watched trademarks of its registry (the worker)
CREATE FUNCTION watch.fn_compare_issue(p_issue_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE m record; n integer := 0;
BEGIN
  FOR m IN SELECT x.registry_id, x.publication_date, x.id FROM watch.published_mark x WHERE x.issue_id = p_issue_id AND x.verify_state <> 'ai_extracted' LOOP
    n := n + watch.fn_compare(m.registry_id, m.publication_date, m.id);
  END LOOP;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_compare_issue(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_compare_issue(uuid) TO meesam_worker;

-- "Compare again" queues one job for the issue
CREATE OR REPLACE FUNCTION watch.fn_issue_compare_again(p_issue_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  SELECT count(*)::int INTO n FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.verify_state <> 'ai_extracted';
  IF n > 0 THEN PERFORM platform.enqueue_job('watch.compare_issue', jsonb_build_object('issue_id', p_issue_id), now(), 'watch.compare_issue:' || p_issue_id); END IF;
  RETURN n;
END $$;

-- 1. the marks of one reading by rules that need no person
CREATE FUNCTION watch.fn_read_run_accept(p_run_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE r record; n integer;
BEGIN
  SELECT u.id, u.issue_id, u.from_page, s.fetch_spec -> 'read' ->> 'accept' AS accept INTO r
    FROM watch.read_run u JOIN watch.publication_issue i ON i.id = u.issue_id JOIN watch.publication_source s ON s.id = i.source_id
   WHERE u.id = p_run_id AND u.model = 'rules';
  IF r.id IS NULL OR r.accept IS DISTINCT FROM 'complete_and_listed' THEN RETURN 0; END IF;
  PERFORM set_config('meesam.bulk_compare', 'on', true);
  WITH idx AS (
    SELECT DISTINCT core.fn_number_key(x ->> 'application_no') AS k
      FROM watch.read_part p, jsonb_array_elements(CASE WHEN jsonb_typeof(p.result -> 'rows') = 'array' THEN p.result -> 'rows' ELSE '[]'::jsonb END) x
     WHERE p.run_id = p_run_id AND p.kind = 'index' AND p.status = 'done'),
  done AS (
    UPDATE watch.published_mark m
       SET verify_state = 'waived', extraction = m.extraction || jsonb_build_object('accepted', 'rules', 'accepted_at', now()), updated_at = now()
     WHERE m.issue_id = r.issue_id AND m.verify_state = 'ai_extracted' AND m.extraction ->> 'run_id' = p_run_id::text AND m.extraction ->> 'read_by' = 'codes'
       AND m.extraction ->> 'confidence' = '1' AND m.application_no IS NOT NULL AND cardinality(m.classes) > 0
       -- a whole issue: the number must be in the office's own list; some pages only: no list was read, completeness decides
       AND (r.from_page IS NOT NULL OR core.fn_number_key(m.application_no) IN (SELECT k FROM idx))
    RETURNING 1)
  SELECT count(*)::int INTO n FROM done;
  PERFORM set_config('meesam.bulk_compare', '', true);
  IF n > 0 THEN PERFORM platform.enqueue_job('watch.compare_issue', jsonb_build_object('issue_id', r.issue_id), now(), 'watch.compare_issue:' || r.issue_id); END IF;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_read_run_accept(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_read_run_accept(uuid) TO meesam_worker;

-- Türkiye: retired for marks read by rules
UPDATE watch.publication_source s SET fetch_spec = jsonb_set(s.fetch_spec, '{read,accept}', '"complete_and_listed"')
  FROM registry.registry g WHERE g.id = s.registry_id AND g.code = 'TR' AND s.stream = 'national_bulletin' AND s.fetch_spec -> 'read' ->> 'method' = 'codes';
-- and for the readings already made
SELECT watch.fn_read_run_accept(u.id) FROM watch.read_run u WHERE u.model = 'rules' AND u.status = 'done' ORDER BY u.created_at;

-- 2. how far back a trademark is compared when it is added to a registry or changed: a setting
INSERT INTO watch.engine_config (version, engine, rules)
  SELECT max(version) + 1, (array_agg(engine ORDER BY version DESC))[1], (array_agg(rules ORDER BY version DESC))[1] || '{"backfill_days": 365}'::jsonb FROM watch.engine_config;
CREATE OR REPLACE FUNCTION watch.fn_compare_record(p_record_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE s record; m record; n integer := 0; v_days integer; cfg watch.engine_config;
BEGIN
  IF NOT COALESCE(core.fn_record_watched(p_record_id), false) THEN RETURN 0; END IF;
  SELECT * INTO cfg FROM watch.engine_config WHERE effective_from <= current_date ORDER BY version DESC LIMIT 1;
  v_days := COALESCE((cfg.rules ->> 'backfill_days')::integer, 365);
  FOR s IN SELECT registry_id FROM core.record_registry_scope WHERE record_id = p_record_id LOOP
    FOR m IN SELECT x.registry_id, x.publication_date, x.id FROM watch.published_mark x
              WHERE x.registry_id = s.registry_id AND x.verify_state <> 'ai_extracted' AND x.publication_date >= current_date - v_days LOOP
      n := n + watch.fn_compare(m.registry_id, m.publication_date, m.id, p_record_id);
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

COMMIT;
