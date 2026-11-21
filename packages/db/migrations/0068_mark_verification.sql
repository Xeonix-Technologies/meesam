-- 0068 — The reviewer's queue (plan item A2; watch rule: human verification of AI-extracted marks stays on per
-- registry until retired by ruling). A mark read by the AI reader waits as "ai_extracted". A publication reviewer or
-- the watch operations lead looks at it beside its gazette page and either confirms it (with corrections where the
-- reader was wrong) or removes it (the reader took something for a mark that is not one). Only a confirmed mark is
-- matched to trademarks and, later, compared for alerts.
-- What the reader gave is kept beside every correction (extraction.read), so the reader's accuracy can be measured
-- per registry. Both actions are audited. Nothing here changes an account's own record (matched, never merged).
BEGIN;

CREATE FUNCTION watch.fn_is_reviewer() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM platform.staff_role r WHERE r.user_id = platform.current_user_id() AND r.role IN ('watch_lead', 'publication_reviewer'))
$$;

-- The worker reads the marks of an issue to cut their pages out for the reviewer.
CREATE POLICY published_mark_worker_read ON watch.published_mark FOR SELECT TO meesam_worker USING (true);
GRANT SELECT ON watch.published_mark TO meesam_worker;

-- The worker records where the mark's own page(s), cut out of the issue, are kept (shown to the reviewer beside the mark).
CREATE FUNCTION watch.fn_mark_page_set(p_issue_id uuid, p_mark_id uuid, p_key text, p_from integer, p_to integer) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
  UPDATE watch.published_mark SET extraction = extraction || jsonb_build_object('page_key', p_key, 'page_from', p_from, 'page_to', p_to)
   WHERE issue_id = p_issue_id AND id = p_mark_id
$$;

-- Confirm one mark. p_fix carries the fields as the reviewer leaves them; a field not given stays as read.
CREATE FUNCTION watch.fn_mark_verify(p_issue_id uuid, p_mark_id uuid, p_fix jsonb DEFAULT '{}'::jsonb) RETURNS text[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE m watch.published_mark; n watch.published_mark; v_changed text[] := '{}'; v_classes smallint[]; v_country text; v_text jsonb; v_extra jsonb; k text;
  f jsonb := COALESCE(p_fix, '{}'::jsonb);
  clean CONSTANT text := '^\s+|\s+$';
BEGIN
  IF NOT watch.fn_is_reviewer() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  SELECT * INTO m FROM watch.published_mark WHERE issue_id = p_issue_id AND id = p_mark_id FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'no such mark' USING ERRCODE = 'P0002'; END IF;
  IF m.verify_state <> 'ai_extracted' THEN RAISE EXCEPTION 'this mark is already verified' USING ERRCODE = '55000'; END IF;
  n := m;
  IF f ? 'application_no' THEN n.application_no := NULLIF(regexp_replace(left(f ->> 'application_no', 60), clean, '', 'g'), ''); END IF;
  IF f ? 'applicant_name' THEN n.applicant_name := NULLIF(regexp_replace(left(f ->> 'applicant_name', 400), clean, '', 'g'), ''); END IF;
  IF f ? 'agent_name' THEN n.agent_name := NULLIF(regexp_replace(left(f ->> 'agent_name', 400), clean, '', 'g'), ''); END IF;
  IF f ? 'applicant_country' THEN
    v_country := upper(btrim(f ->> 'applicant_country'));
    IF v_country = '' THEN v_country := NULL; END IF;
    IF v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'the country is a two-letter code' USING ERRCODE = '22023'; END IF;
    n.applicant_country := v_country;
  END IF;
  IF f ? 'mark_text_ar' OR f ? 'mark_text_en' THEN
    v_text := jsonb_strip_nulls(jsonb_build_object(
      'ar', CASE WHEN f ? 'mark_text_ar' THEN NULLIF(regexp_replace(left(f ->> 'mark_text_ar', 300), clean, '', 'g'), '') ELSE m.mark_text ->> 'ar' END,
      'en', CASE WHEN f ? 'mark_text_en' THEN NULLIF(regexp_replace(left(f ->> 'mark_text_en', 300), clean, '', 'g'), '') ELSE m.mark_text ->> 'en' END));
    n.mark_text := NULLIF(v_text, '{}'::jsonb);
  END IF;
  IF f ? 'classes' THEN
    IF jsonb_typeof(f -> 'classes') <> 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(f -> 'classes') c WHERE c !~ '^\d{1,2}$' OR c::int NOT BETWEEN 1 AND 45) THEN
      RAISE EXCEPTION 'classes are numbers from 1 to 45' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(array_agg(DISTINCT c::smallint ORDER BY c::smallint), '{}') INTO v_classes FROM jsonb_array_elements_text(f -> 'classes') c;
    n.classes := v_classes;
  END IF;
  -- fields that live beside the mark: filing date and the agent's city
  v_extra := m.extraction;
  IF f ? 'filing_date' THEN
    IF NULLIF(btrim(f ->> 'filing_date'), '') IS NOT NULL AND f ->> 'filing_date' !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'the filing date is a date' USING ERRCODE = '22007'; END IF;
    v_extra := v_extra || jsonb_build_object('filing_date', NULLIF(btrim(f ->> 'filing_date'), ''));
  END IF;
  IF f ? 'agent_city' THEN v_extra := v_extra || jsonb_build_object('agent_city', NULLIF(regexp_replace(left(f ->> 'agent_city', 120), clean, '', 'g'), '')); END IF;

  IF n.application_no IS DISTINCT FROM m.application_no THEN v_changed := v_changed || 'application_no'::text; END IF;
  IF n.mark_text IS DISTINCT FROM m.mark_text THEN v_changed := v_changed || 'mark_text'::text; END IF;
  IF n.classes IS DISTINCT FROM m.classes THEN v_changed := v_changed || 'classes'::text; END IF;
  IF n.applicant_name IS DISTINCT FROM m.applicant_name THEN v_changed := v_changed || 'applicant_name'::text; END IF;
  IF n.applicant_country IS DISTINCT FROM m.applicant_country THEN v_changed := v_changed || 'applicant_country'::text; END IF;
  IF n.agent_name IS DISTINCT FROM m.agent_name THEN v_changed := v_changed || 'agent_name'::text; END IF;
  FOREACH k IN ARRAY ARRAY['filing_date', 'agent_city'] LOOP
    IF v_extra ->> k IS DISTINCT FROM m.extraction ->> k THEN v_changed := v_changed || k; END IF;
  END LOOP;
  -- one number once in an issue
  IF n.application_no IS NOT NULL AND EXISTS (SELECT 1 FROM watch.published_mark x WHERE x.issue_id = p_issue_id AND x.id <> m.id
       AND core.fn_number_key(x.application_no) = core.fn_number_key(n.application_no)) THEN
    RAISE EXCEPTION 'another mark of this issue carries this number' USING ERRCODE = '23505';
  END IF;
  -- what the reader gave is kept once, before the first correction
  IF cardinality(v_changed) > 0 AND NOT (v_extra ? 'read') THEN
    v_extra := v_extra || jsonb_build_object('read', jsonb_build_object('application_no', m.application_no, 'mark_text', m.mark_text, 'classes', to_jsonb(m.classes),
      'applicant_name', m.applicant_name, 'applicant_country', m.applicant_country, 'agent_name', m.agent_name, 'filing_date', m.extraction -> 'filing_date', 'agent_city', m.extraction -> 'agent_city'));
  END IF;
  v_extra := v_extra || jsonb_build_object('corrected', to_jsonb(v_changed), 'verified_at', now());
  UPDATE watch.published_mark SET application_no = n.application_no, mark_text = n.mark_text, classes = n.classes, applicant_name = n.applicant_name,
         applicant_country = n.applicant_country, agent_name = n.agent_name, extraction = v_extra, verify_state = 'human_verified',
         verified_by_user_id = platform.current_user_id(), updated_at = now()
   WHERE registry_id = m.registry_id AND publication_date = m.publication_date AND id = m.id;
  INSERT INTO platform.audit_event (user_id, schema_name, table_name, row_id, action, before, after)
  VALUES (platform.current_user_id(), 'watch', 'published_mark', m.id, 'UPDATE', to_jsonb(m) - 'mark_text_norm' - 'phonetic_key',
          jsonb_build_object('verify_state', 'human_verified', 'corrected', to_jsonb(v_changed), 'application_no', n.application_no, 'mark_text', n.mark_text,
                             'classes', to_jsonb(n.classes), 'applicant_name', n.applicant_name, 'applicant_country', n.applicant_country, 'agent_name', n.agent_name));
  RETURN v_changed;
END $$;

-- Remove something the reader took for a mark (not an entry, or the same entry twice). Only an unverified mark; a reason is required.
CREATE FUNCTION watch.fn_mark_reject(p_issue_id uuid, p_mark_id uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE m watch.published_mark; v_reason text := NULLIF(btrim(left(p_reason, 300)), '');
BEGIN
  IF NOT watch.fn_is_reviewer() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023'; END IF;
  SELECT * INTO m FROM watch.published_mark WHERE issue_id = p_issue_id AND id = p_mark_id FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'no such mark' USING ERRCODE = 'P0002'; END IF;
  IF m.verify_state <> 'ai_extracted' THEN RAISE EXCEPTION 'a verified mark is not removed here' USING ERRCODE = '55000'; END IF;
  DELETE FROM watch.published_mark WHERE registry_id = m.registry_id AND publication_date = m.publication_date AND id = m.id;
  INSERT INTO platform.audit_event (user_id, schema_name, table_name, row_id, action, before, after)
  VALUES (platform.current_user_id(), 'watch', 'published_mark', m.id, 'DELETE', to_jsonb(m) - 'mark_text_norm' - 'phonetic_key', jsonb_build_object('reason', v_reason));
END $$;

REVOKE EXECUTE ON FUNCTION watch.fn_is_reviewer(), watch.fn_mark_page_set(uuid, uuid, text, integer, integer), watch.fn_mark_verify(uuid, uuid, jsonb), watch.fn_mark_reject(uuid, uuid, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_is_reviewer(), watch.fn_mark_verify(uuid, uuid, jsonb), watch.fn_mark_reject(uuid, uuid, text) TO meesam_staff, meesam_admin;
GRANT EXECUTE ON FUNCTION watch.fn_mark_page_set(uuid, uuid, text, integer, integer) TO meesam_worker;

-- Issues already read (before this migration) get their marks' pages cut out for the reviewer.
SELECT platform.enqueue_job('watch.mark_pages', jsonb_build_object('issue_id', i.issue_id), now(), 'watch.mark_pages:' || i.issue_id)
  FROM (SELECT DISTINCT issue_id FROM watch.published_mark WHERE verify_state = 'ai_extracted') i;

COMMIT;
