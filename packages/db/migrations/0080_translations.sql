-- 0080 — Translation of what a registry published, beside the registry's own text (Founder rulings 21 and 22 Nov 2026:
-- all fields except the mark's own wording, into the user's language; "No translation done, at least to English").
-- A translation is made by the AI reader, kept beside the published mark per language (extraction.t.<lang>), and
-- never replaces the registry's wording (rule 13: published data is kept as published). The mark's own wording is
-- never translated. It is made when someone needs it, not for every mark:
--   * for the reviewer, when asked in the queue;
--   * for an account, when an alert is raised, in the languages of that account's users.
BEGIN;

-- A reviewer or the lead asks for one mark to be translated.
CREATE FUNCTION watch.fn_translation_request(p_issue_id uuid, p_mark_id uuid, p_lang text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_reviewer() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF p_lang IS NULL OR p_lang !~ '^[a-z]{2}$' THEN RAISE EXCEPTION 'a two-letter language code is required' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM watch.published_mark WHERE issue_id = p_issue_id AND id = p_mark_id) THEN RAISE EXCEPTION 'no such mark' USING ERRCODE = 'P0002'; END IF;
  PERFORM platform.enqueue_job('watch.translate', jsonb_build_object('issue_id', p_issue_id, 'mark_id', p_mark_id, 'lang', p_lang), now(), 'watch.translate:' || p_mark_id || ':' || p_lang);
END $$;

-- The worker keeps the translation beside the mark.
CREATE FUNCTION watch.fn_translation_store(p_issue_id uuid, p_mark_id uuid, p_lang text, p_t jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
  UPDATE watch.published_mark
     SET extraction = jsonb_set(CASE WHEN extraction ? 't' THEN extraction ELSE extraction || '{"t": {}}'::jsonb END, ARRAY['t', p_lang], COALESCE(p_t, '{}'::jsonb) || jsonb_build_object('at', now()))
   WHERE issue_id = p_issue_id AND id = p_mark_id AND p_lang ~ '^[a-z]{2}$'
$$;

-- When an alert is raised, the published mark is translated into the languages of the account's users.
CREATE FUNCTION watch.trg_alert_translate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, platform, public, pg_temp AS $$
DECLARE m record; l record;
BEGIN
  SELECT pm.id, pm.issue_id, pm.extraction INTO m FROM watch.candidate c JOIN watch.published_mark pm ON pm.id = c.published_mark_id AND pm.registry_id = NEW.registry_id WHERE c.id = NEW.candidate_id;
  IF m.id IS NULL THEN RETURN NULL; END IF;
  FOR l IN SELECT DISTINCT left(u.locale::text, 2) AS lang FROM core.app_user u WHERE u.account_id = NEW.account_id AND u.status = 'active' LOOP
    IF l.lang ~ '^[a-z]{2}$' AND NOT COALESCE(m.extraction -> 't' ? l.lang, false) THEN
      PERFORM platform.enqueue_job('watch.translate', jsonb_build_object('issue_id', m.issue_id, 'mark_id', m.id, 'lang', l.lang), now(), 'watch.translate:' || m.id || ':' || l.lang);
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER alert_translate AFTER INSERT ON watch.alert FOR EACH ROW EXECUTE FUNCTION watch.trg_alert_translate();

REVOKE EXECUTE ON FUNCTION watch.fn_translation_request(uuid, uuid, text), watch.fn_translation_store(uuid, uuid, text, jsonb) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_translation_request(uuid, uuid, text) TO meesam_staff, meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_translation_store(uuid, uuid, text, jsonb) TO meesam_worker;

-- alerts already raised get their translations too
SELECT platform.enqueue_job('watch.translate', jsonb_build_object('issue_id', pm.issue_id, 'mark_id', pm.id, 'lang', x.lang), now(), 'watch.translate:' || pm.id || ':' || x.lang)
  FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id JOIN watch.published_mark pm ON pm.id = c.published_mark_id AND pm.registry_id = a.registry_id,
       LATERAL (SELECT DISTINCT left(u.locale::text, 2) AS lang FROM core.app_user u WHERE u.account_id = a.account_id AND u.status = 'active') x
 WHERE x.lang ~ '^[a-z]{2}$';

COMMIT;
