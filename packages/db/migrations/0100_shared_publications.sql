-- 0100 — Publications shown to signed-in accounts (Founder, 26 Nov 2026).
--
-- The Founder wants the bulletins Meesam holds to be seen and downloaded inside Meesam by signed-in owners and
-- agencies, the UAE first, to show the ministry an easier way to reach its own bulletin. It is not a public page
-- and not a search: a signed-in account sees the list of issues of a registry and may download the file exactly
-- as the registry published it, with its source named.
-- Kept behind a switch per source, off everywhere until the watch operations lead switches it on with a stated
-- basis (the registry's agreement, or the Founder's ruling), recorded with who and when. A source whose re-use
-- is not confirmed cannot be shown.
BEGIN;

ALTER TABLE watch.publication_source
  ADD COLUMN shown_to_accounts boolean NOT NULL DEFAULT false,
  ADD COLUMN shown_basis       text NULL,
  ADD COLUMN shown_by          uuid NULL REFERENCES core.app_user(id),
  ADD COLUMN shown_since       timestamptz NULL;

CREATE FUNCTION watch.fn_source_show(p_source_id uuid, p_on boolean, p_basis text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_basis text := NULLIF(btrim(left(p_basis, 300)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF p_on AND v_basis IS NULL THEN RAISE EXCEPTION 'the basis is required' USING ERRCODE = '22023'; END IF;
  UPDATE watch.publication_source
     SET shown_to_accounts = p_on, shown_basis = CASE WHEN p_on THEN v_basis END,
         shown_by = CASE WHEN p_on THEN platform.current_user_id() END, shown_since = CASE WHEN p_on THEN now() END, updated_at = now()
   WHERE id = p_source_id AND active;      -- re-use must be confirmed first
  IF NOT FOUND THEN RAISE EXCEPTION 'no such source with re-use confirmed' USING ERRCODE = 'P0002'; END IF;
END $$;

-- What a signed-in account may see: the issues held of the sources switched on, newest first, with how many
-- applications and other notices Meesam read from each. Nothing of a source that is not switched on.
CREATE FUNCTION watch.fn_shared_issues()
RETURNS TABLE (id uuid, registry_code text, registry_name jsonb, stream text, issue_no text, published_on date, size_bytes bigint, container text, location text, marks integer, notices integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, public, pg_temp AS $$
  SELECT i.id, g.code::text, g.name, s.stream::text, i.issue_no, i.published_on, i.size_bytes, COALESCE(i.container, 'pdf'),
         COALESCE(s.fetch_spec ->> 'manual_page', s.fetch_spec ->> 'url'),
         (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = i.id),
         (SELECT count(*)::int FROM watch.published_notice n WHERE n.issue_id = i.id)
    FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id
   WHERE s.shown_to_accounts AND s.active AND i.object_key IS NOT NULL AND i.object_key !~ '^_mail/'
   ORDER BY i.published_on DESC NULLS LAST, i.issue_no DESC
   LIMIT 500
$$;

-- Where one such issue is kept, for the download; nothing for an issue of a source that is not switched on.
CREATE FUNCTION watch.fn_shared_issue_file(p_issue_id uuid)
RETURNS TABLE (object_key text, container text, registry_code text, issue_no text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, public, pg_temp AS $$
  SELECT i.object_key, COALESCE(i.container, 'pdf'), g.code::text, i.issue_no
    FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id
   WHERE i.id = p_issue_id AND s.shown_to_accounts AND s.active AND i.object_key IS NOT NULL AND i.object_key !~ '^_mail/'
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_source_show(uuid, boolean, text) FROM PUBLIC, meesam_app;
REVOKE EXECUTE ON FUNCTION watch.fn_shared_issues(), watch.fn_shared_issue_file(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION watch.fn_source_show(uuid, boolean, text) TO meesam_staff;
GRANT EXECUTE ON FUNCTION watch.fn_shared_issues(), watch.fn_shared_issue_file(uuid) TO meesam_app, meesam_staff, meesam_admin;

COMMIT;
