-- 0070 — Watch scope per trademark (MSM-PRD-02 Section 7) and what the comparing did, for the console.
-- A trademark is watched in its own registry by default. The account that holds it may add any other registry that
-- Meesam reads (a "watch-only" registry: the mark is not filed there) and remove one it added; the registry where
-- the mark is filed cannot be removed here. Every change is audited and the other side is notified by the table's
-- audit trigger (item 39); adding a registry queues the comparison with what that registry has already published.
-- Price (Price List v1.0): a watch-only registry is charged from configuration when payments open; the pilot is free.
BEGIN;

CREATE FUNCTION core.fn_record_watch_set(p_record_id uuid, p_registry_id uuid, p_on boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, watch, registry, platform, public, pg_temp AS $$
DECLARE k core.scope_kind;
BEGIN
  IF NOT core.fn_can_access(p_record_id, platform.current_account_id(), true) THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  SELECT kind INTO k FROM core.record_registry_scope WHERE record_id = p_record_id AND registry_id = p_registry_id;
  IF p_on THEN
    IF k IS NOT NULL THEN RETURN; END IF;
    -- only a registry whose publications Meesam reads
    IF NOT EXISTS (SELECT 1 FROM watch.publication_source s WHERE s.registry_id = p_registry_id AND s.active) THEN
      RAISE EXCEPTION 'Meesam does not read this registry yet' USING ERRCODE = '22023';
    END IF;
    INSERT INTO core.record_registry_scope (record_id, registry_id, kind) VALUES (p_record_id, p_registry_id, 'watch_only');
  ELSE
    IF k IS NULL THEN RETURN; END IF;
    IF k = 'filed' THEN RAISE EXCEPTION 'the registry where the mark is filed stays watched' USING ERRCODE = '55000'; END IF;
    DELETE FROM core.record_registry_scope WHERE record_id = p_record_id AND registry_id = p_registry_id;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_record_watch_set(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_record_watch_set(uuid, uuid, boolean) TO meesam_app;

-- For the Operations Console: what comparing the verified marks of an issue produced. Counts only; no account is named.
CREATE FUNCTION watch.fn_issue_compare_summary(p_issue_id uuid, OUT verified integer, OUT compared integer, OUT matches integer, OUT alerts integer, OUT held integer, OUT own integer, OUT waiting_jobs integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
  SELECT (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.verify_state <> 'ai_extracted'),
         (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.verify_state <> 'ai_extracted'
             AND NOT EXISTS (SELECT 1 FROM platform.job j WHERE j.kind = 'watch.compare' AND j.status IN ('queued', 'running') AND j.payload ->> 'mark_id' = m.id::text)),
         (SELECT count(*)::int FROM watch.candidate c JOIN watch.comparison_run r ON r.id = c.run_id WHERE r.issue_id = p_issue_id),
         (SELECT count(*)::int FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id JOIN watch.comparison_run r ON r.id = c.run_id WHERE r.issue_id = p_issue_id),
         (SELECT count(*)::int FROM watch.candidate c JOIN watch.comparison_run r ON r.id = c.run_id WHERE r.issue_id = p_issue_id AND c.explanation ->> 'held' = 'reuse_show' AND c.explanation ->> 'class' <> 'outside' AND c.explanation ->> 'band' <> 'low' AND NOT (c.explanation ->> 'own')::boolean),
         (SELECT count(*)::int FROM watch.candidate c JOIN watch.comparison_run r ON r.id = c.run_id WHERE r.issue_id = p_issue_id AND (c.explanation ->> 'own')::boolean),
         (SELECT count(*)::int FROM platform.job j JOIN watch.published_mark m ON m.id::text = j.payload ->> 'mark_id' WHERE j.kind = 'watch.compare' AND j.status IN ('queued', 'running') AND m.issue_id = p_issue_id)
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_compare_summary(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_compare_summary(uuid) TO meesam_staff, meesam_admin;

-- A deadline is not shown where the date it runs from is not confirmed for that publication stream. Qatar's own
-- gazette carries its date and the 60-day period is verified in its profile; for Qatar's Madrid gazette it is not
-- known whether the posting date is the date the period runs from (migration 0049; ruling R7, 21 Nov 2026), so an
-- alert from that stream carries no computed deadline: the account enters it. The hold is data on the source.
UPDATE watch.publication_source s SET fetch_spec = s.fetch_spec || '{"deadline_basis": "unconfirmed"}'::jsonb
  FROM registry.registry g WHERE g.id = s.registry_id AND g.code = 'QA' AND s.stream::text LIKE 'madrid%';

CREATE FUNCTION watch.trg_alert_deadline_hold() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
BEGIN
  IF NEW.opposition_deadline IS NOT NULL AND NEW.deadline_entered_by IS NULL AND EXISTS (
       SELECT 1 FROM watch.candidate c JOIN watch.published_mark m ON m.id = c.published_mark_id AND m.registry_id = NEW.registry_id
         JOIN watch.publication_issue i ON i.id = m.issue_id JOIN watch.publication_source s ON s.id = i.source_id
        WHERE c.id = NEW.candidate_id AND s.fetch_spec ->> 'deadline_basis' = 'unconfirmed') THEN
    NEW.opposition_deadline := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER alert_deadline_hold BEFORE INSERT ON watch.alert FOR EACH ROW EXECUTE FUNCTION watch.trg_alert_deadline_hold();

COMMIT;
