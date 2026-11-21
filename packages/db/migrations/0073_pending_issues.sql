-- 0073 — Publications still under review, shown to the accounts that watch that registry (MSM-PRD-02 Section 8.5,
-- ruled 31 Oct 2026: "publication of [date] under review, n marks", so a window never passes silently).
-- An issue is under review while it is stored but not yet read, or while any of its marks still waits for a person.
-- The account sees only the registry, the issue, its date and a count; no mark is shown before it is verified.
BEGIN;

CREATE FUNCTION watch.fn_pending_issues() RETURNS TABLE (registry_code text, issue_no text, published_on date, marks integer, waiting integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
  SELECT g.code::text, i.issue_no, i.published_on,
         (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = i.id),
         (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = i.id AND m.verify_state = 'ai_extracted')
    FROM watch.publication_issue i
    JOIN watch.publication_source s ON s.id = i.source_id
    JOIN registry.registry g ON g.id = s.registry_id
   WHERE i.object_key IS NOT NULL AND COALESCE(i.published_on, i.created_at::date) >= current_date - 120
     AND s.registry_id IN (SELECT sc.registry_id FROM core.record_registry_scope sc JOIN core.v_record_access a ON a.record_id = sc.record_id
                            WHERE a.account_id = platform.current_account_id() AND core.fn_record_watched(sc.record_id))
     AND (NOT EXISTS (SELECT 1 FROM watch.published_mark m WHERE m.issue_id = i.id)
          OR EXISTS (SELECT 1 FROM watch.published_mark m WHERE m.issue_id = i.id AND m.verify_state = 'ai_extracted'))
   ORDER BY i.published_on DESC NULLS LAST, i.issue_no
   LIMIT 20
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_pending_issues() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION watch.fn_pending_issues() TO meesam_app;

COMMIT;
