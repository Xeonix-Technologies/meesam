-- 0101 — One issue left out of the Publications page (Founder, 27 Nov 2026).
--
-- A registry whose bulletins are shown to signed-in accounts (0100) may hold an issue that should not be listed
-- there: an early test file, a partial issue, one entered with a wrong number. The watch operations lead leaves
-- such an issue out, or puts it back, on the Publications inbox. Nothing else about the issue changes: it stays
-- stored, read and compared.
BEGIN;

ALTER TABLE watch.publication_issue ADD COLUMN hidden_from_accounts boolean NOT NULL DEFAULT false;

CREATE FUNCTION watch.fn_issue_hide(p_issue_id uuid, p_hidden boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  UPDATE watch.publication_issue SET hidden_from_accounts = p_hidden, updated_at = now() WHERE id = p_issue_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such issue' USING ERRCODE = 'P0002'; END IF;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_hide(uuid, boolean) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_hide(uuid, boolean) TO meesam_staff;

CREATE OR REPLACE FUNCTION watch.fn_shared_issues()
RETURNS TABLE (id uuid, registry_code text, registry_name jsonb, stream text, issue_no text, published_on date, size_bytes bigint, container text, location text, marks integer, notices integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, public, pg_temp AS $$
  SELECT i.id, g.code::text, g.name, s.stream::text, i.issue_no, i.published_on, i.size_bytes, COALESCE(i.container, 'pdf'),
         COALESCE(s.fetch_spec ->> 'manual_page', s.fetch_spec ->> 'url'),
         (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = i.id),
         (SELECT count(*)::int FROM watch.published_notice n WHERE n.issue_id = i.id)
    FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id
   WHERE s.shown_to_accounts AND s.active AND NOT i.hidden_from_accounts AND i.object_key IS NOT NULL AND i.object_key !~ '^_mail/'
   ORDER BY i.published_on DESC NULLS LAST, i.issue_no DESC
   LIMIT 500
$$;

CREATE OR REPLACE FUNCTION watch.fn_shared_issue_file(p_issue_id uuid)
RETURNS TABLE (object_key text, container text, registry_code text, issue_no text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, public, pg_temp AS $$
  SELECT i.object_key, COALESCE(i.container, 'pdf'), g.code::text, i.issue_no
    FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id
   WHERE i.id = p_issue_id AND s.shown_to_accounts AND s.active AND NOT i.hidden_from_accounts AND i.object_key IS NOT NULL AND i.object_key !~ '^_mail/'
$$;

COMMIT;
