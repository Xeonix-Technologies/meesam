-- 0081 — Reading a bulletin by its printed codes (Türkiye first); and the console says why no alert was raised.
--
-- A. Found on staging, 22 Nov 2026 (the Founder's test with "oro selekt"): a match was kept but no alert showed, and
--    the console did not say why. The match was held back because "show" is not yet confirmed in the re-use register;
--    the count of held matches missed it, because "is this the account's own publication" was left unknown (neither
--    yes nor no) when the account's name is written in one script only. Unknown is now "no", the console counts held
--    matches correctly, shows how many watched trademarks a registry has (counts only, never whose), and the lead
--    can have an issue compared again (after a registry is added to a trademark, for example).
-- B. Founder ruling 22 Nov 2026: a large bulletin whose entries carry printed codes ((210) number, (731) applicant,
--    (540) wording, (511) classes, (510) goods) is read from the file's own text by rules, without the AI reader.
--    Checked against Türkiye's bulletin 495 (3,756 pages): 8,405 entries read in about half a minute, and in each of
--    its four sections the numbers read are exactly the numbers the office lists at the head of the section.
--    Which code means what, the labels and the section headings are data on the source (fetch_spec.read).
--    The marks still wait for a person, as rule 7 says for marks read by the AI reader.
--    RULING NEEDED: whether a mark read by rules, complete and present in the office's own list, needs a person.
BEGIN;

-- A1. the comparison, with "own" never left unknown
CREATE OR REPLACE FUNCTION watch.fn_compare(p_registry_id uuid, p_publication_date date, p_mark_id uuid, p_record_id uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE m watch.published_mark; cfg watch.engine_config; th watch.threshold; reg registry.registry_profile; u watch.reuse_register;
        r record; t record; v_run uuid; v_cand uuid; v_overlap smallint[]; v_score numeric; v_band watch.risk_band;
        v_own boolean; v_expl jsonb; v_deadline date; v_new integer := 0; a record; w jsonb; v_alert uuid; v_rc smallint[];
BEGIN
  SELECT * INTO m FROM watch.published_mark WHERE registry_id = p_registry_id AND publication_date = p_publication_date AND id = p_mark_id;
  IF m.id IS NULL OR m.verify_state = 'ai_extracted' OR m.mark_text_norm IS NULL OR m.mark_text_norm = '{}'::jsonb THEN RETURN 0; END IF;
  SELECT * INTO u FROM watch.reuse_register WHERE registry_id = m.registry_id;
  IF u.may_derive IS FALSE THEN RETURN 0; END IF;
  SELECT * INTO cfg FROM watch.engine_config WHERE effective_from <= current_date ORDER BY version DESC LIMIT 1;
  w := cfg.rules;   -- the weights and the words that are skipped
  SELECT * INTO th FROM watch.threshold x WHERE (x.scope = 'registry' AND x.scope_id = m.registry_id) OR x.scope = 'global'
   ORDER BY (x.scope = 'registry') DESC, x.version DESC LIMIT 1;
  reg := registry.fn_current_profile(m.registry_id, m.publication_date);
  v_deadline := watch.fn_opposition_deadline(m.registry_id, m.publication_date);
  IF m.opposition_deadline IS DISTINCT FROM v_deadline THEN
    UPDATE watch.published_mark SET opposition_deadline = v_deadline WHERE registry_id = m.registry_id AND publication_date = m.publication_date AND id = m.id;
  END IF;

  FOR r IN
    SELECT rec.id, rec.mark_text_norm, f.owner_account_id, acc.name AS owner_name,
           COALESCE((SELECT array_agg(n.number ORDER BY n.number) FROM core.record_class rc JOIN registry.nice_class n ON n.id = rc.nice_class_id WHERE rc.record_id = rec.id), '{}') AS classes
      FROM core.record rec
      JOIN core.record_registry_scope s ON s.record_id = rec.id AND s.registry_id = m.registry_id
      JOIN core.mark_family f ON f.id = rec.mark_family_id
      LEFT JOIN core.account acc ON acc.id = f.owner_account_id
     WHERE (p_record_id IS NULL OR rec.id = p_record_id) AND rec.mark_text_norm IS NOT NULL AND rec.mark_text_norm <> '{}'::jsonb
       AND core.fn_record_watched(rec.id)
  LOOP
    SELECT * INTO t FROM watch.fn_text_match(r.mark_text_norm, m.mark_text_norm, w);
    CONTINUE WHEN t.best < th.floor;
    v_rc := r.classes;
    SELECT COALESCE(array_agg(c ORDER BY c), '{}') INTO v_overlap FROM unnest(m.classes) c WHERE c = ANY (v_rc);
    -- The class is information, not a gate (Founder ruling 22 Nov 2026): every match is kept whatever its class;
    -- the alert says whether a class is shared, and the reader decides.
    v_score := t.best;
    v_band := CASE WHEN v_score >= th.band_very_high THEN 'very_high' WHEN v_score >= th.band_high THEN 'high'
                   WHEN v_score >= th.band_medium THEN 'medium' ELSE 'low' END;
    -- the account's own publication: the same application as the trademark, or the owner's own name as applicant
    -- (a name the account does not carry in one of the two scripts must not leave this unknown: unknown is "not its own")
    v_own := COALESCE(EXISTS (SELECT 1 FROM watch.record_match x WHERE x.record_id = r.id AND x.mark_id = m.id)
          OR (m.applicant_name IS NOT NULL AND r.owner_name IS NOT NULL AND (
                watch.fn_strip_entity(watch.fn_normalise_latin(m.applicant_name)) IN (watch.fn_strip_entity(watch.fn_normalise_latin(r.owner_name ->> 'en')), watch.fn_strip_entity(watch.fn_normalise_latin(r.owner_name ->> 'ar')))
             OR watch.fn_strip_entity(watch.fn_normalise_arabic(m.applicant_name)) IN (watch.fn_strip_entity(watch.fn_normalise_arabic(r.owner_name ->> 'ar')), watch.fn_strip_entity(watch.fn_normalise_arabic(r.owner_name ->> 'en'))))), false);
    v_expl := jsonb_build_object('engine', cfg.engine, 'config', cfg.version, 'reasons', t.reasons, 'text_best', t.best,
                                 'class', CASE WHEN cardinality(v_overlap) > 0 THEN 'same' ELSE 'different' END,
                                 'band', v_band, 'own', v_own, 'mark_classes', to_jsonb(m.classes), 'record_classes', to_jsonb(v_rc),
                                 'held', CASE WHEN u.may_show IS NOT TRUE THEN 'reuse_show' END);

    IF v_run IS NULL THEN
      INSERT INTO watch.comparison_run (issue_id, engine_version) VALUES (m.issue_id, cfg.engine)
      ON CONFLICT (issue_id, engine_version) WHERE issue_id IS NOT NULL DO UPDATE SET updated_at = now() RETURNING id INTO v_run;
    END IF;
    SELECT c.id INTO v_cand FROM watch.candidate c WHERE c.published_mark_id = m.id AND c.record_id = r.id ORDER BY c.created_at LIMIT 1;
    IF v_cand IS NULL THEN
      INSERT INTO watch.candidate (run_id, published_mark_id, record_id, score_text, score_phonetic, score_cross_mode, score, class_overlap, explanation)
      VALUES (v_run, m.id, r.id, t.score_text, t.score_phonetic, t.score_cross, v_score, v_overlap, v_expl) RETURNING id INTO v_cand;
      UPDATE watch.comparison_run SET candidates = candidates + 1, updated_at = now() WHERE id = v_run;
    ELSE
      UPDATE watch.candidate SET score_text = t.score_text, score_phonetic = t.score_phonetic, score_cross_mode = t.score_cross, score = v_score,
             class_overlap = v_overlap, explanation = v_expl, updated_at = now() WHERE id = v_cand;
    END IF;
    IF v_own THEN
      INSERT INTO watch.own_filing_suppression (record_id, published_mark_id) VALUES (r.id, m.id) ON CONFLICT DO NOTHING;
      CONTINUE;
    END IF;
    -- Very high, High and Medium raise an alert; Low is kept and listed on the trademark's page only
    CONTINUE WHEN v_band = 'low' OR u.may_show IS NOT TRUE;
    -- one alert per account that holds the trademark (owner, appointed agency, instructed office); never shared between accounts
    FOR a IN SELECT DISTINCT x.account_id FROM core.v_record_access x WHERE x.record_id = r.id AND x.account_id IS NOT NULL LOOP
      INSERT INTO watch.alert (candidate_id, record_id, registry_id, account_id, risk_band, opposition_deadline)
      VALUES (v_cand, r.id, m.registry_id, a.account_id, v_band, v_deadline)
      ON CONFLICT (candidate_id, account_id) DO NOTHING RETURNING id INTO v_alert;
      IF v_alert IS NOT NULL THEN
        v_new := v_new + 1;
        INSERT INTO platform.notification (account_id, channel, kind, record_id, payload, dedupe_key)
        VALUES (a.account_id, 'in_app', 'alert_new', r.id, jsonb_build_object('alert_id', v_alert, 'band', v_band, 'registry_id', m.registry_id), 'alert_new:' || v_alert);
      END IF;
    END LOOP;
  END LOOP;
  IF v_run IS NOT NULL THEN UPDATE watch.comparison_run SET finished_at = now(), updated_at = now() WHERE id = v_run; END IF;
  RETURN v_new;
END $$;

-- A2. what comparing an issue's marks produced, in counts only
DROP FUNCTION watch.fn_issue_compare_summary(uuid);
CREATE FUNCTION watch.fn_issue_compare_summary(p_issue_id uuid, OUT verified integer, OUT compared integer, OUT matches integer, OUT alerts integer, OUT held integer, OUT own integer,
                                               OUT waiting_jobs integer, OUT low integer, OUT watched integer, OUT may_show boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, core, platform, public, pg_temp AS $$
  WITH c AS (SELECT c.id, c.explanation, COALESCE((c.explanation ->> 'own')::boolean, false) AS own FROM watch.candidate c JOIN watch.comparison_run r ON r.id = c.run_id WHERE r.issue_id = p_issue_id),
       g AS (SELECT s.registry_id FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id WHERE i.id = p_issue_id)
  SELECT (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.verify_state <> 'ai_extracted'),
         (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.verify_state <> 'ai_extracted'
             AND NOT EXISTS (SELECT 1 FROM platform.job j WHERE j.kind = 'watch.compare' AND j.status IN ('queued', 'running') AND j.payload ->> 'mark_id' = m.id::text)),
         (SELECT count(*)::int FROM c),
         (SELECT count(*)::int FROM watch.alert a JOIN c ON c.id = a.candidate_id),
         -- kept, strong enough to alert, not the account's own, and with no alert: held back by the re-use register
         (SELECT count(*)::int FROM c WHERE NOT c.own AND c.explanation ->> 'band' <> 'low' AND NOT EXISTS (SELECT 1 FROM watch.alert a WHERE a.candidate_id = c.id)),
         (SELECT count(*)::int FROM c WHERE c.own),
         (SELECT count(*)::int FROM platform.job j JOIN watch.published_mark m ON m.id::text = j.payload ->> 'mark_id' WHERE j.kind = 'watch.compare' AND j.status IN ('queued', 'running') AND m.issue_id = p_issue_id),
         (SELECT count(*)::int FROM c WHERE NOT c.own AND c.explanation ->> 'band' = 'low'),
         -- how many trademarks are watched in this registry, across all accounts (a number only)
         (SELECT count(*)::int FROM core.record_registry_scope s JOIN g ON g.registry_id = s.registry_id WHERE core.fn_record_watched(s.record_id)),
         (SELECT u.may_show IS TRUE FROM g LEFT JOIN watch.reuse_register u ON u.registry_id = g.registry_id)
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_compare_summary(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_compare_summary(uuid) TO meesam_staff, meesam_admin;

-- A3. the lead has every verified mark of an issue compared again, whatever the issue's date
CREATE FUNCTION watch.fn_issue_compare_again(p_issue_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  SELECT count(platform.enqueue_job('watch.compare', jsonb_build_object('registry_id', m.registry_id, 'publication_date', m.publication_date, 'mark_id', m.id), now(), 'watch.compare:' || m.id))::int INTO n
    FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.verify_state <> 'ai_extracted';
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_issue_compare_again(uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_issue_compare_again(uuid) TO meesam_staff, meesam_admin;

-- matches kept while "own" was unknown are looked at again
SELECT platform.enqueue_job('watch.compare_registry', jsonb_build_object('registry_id', x.registry_id), now(), 'watch.compare_registry:' || x.registry_id)
  FROM (SELECT DISTINCT registry_id FROM watch.published_mark WHERE verify_state <> 'ai_extracted') x;

-- B1. Türkiye's bulletin is read by its printed codes. Every value here is the office's own wording, as data.
UPDATE watch.publication_source s
   SET fetch_spec = jsonb_set(s.fetch_spec, '{read}', COALESCE(s.fetch_spec -> 'read', '{}'::jsonb) || '{
         "method": "codes",
         "codes": {"number": "210", "filed": "220", "applicant": "731", "mark": "540", "classes": "511", "goods": "510", "figure": "531"},
         "agent_label": "Vekil:",
         "excluded_label": "Çıkarılan Mal/Hizmetler:",
         "wording_kinds": {"şekil": "device", "ses markası": "sound", "hareket markası": "motion", "üçboyutlu marka": "three_dimensional"},
         "columns": 2,
         "head_height": 32,
         "number_pattern": "\\d{4}/\\d{6}",
         "toc_heading": "İçindekiler",
         "sections": "İlan Edildiği Bölüm",
         "observed": "22 Nov 2026, bulletin 495 of 29 Jun 2026: two columns; an entry runs from its (210) line to the next; four sections publish applications (national, Madrid, and the two decided by the re-examination board), each headed by the list of its numbers"
       }'::jsonb)
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'TR' AND s.stream = 'national_bulletin';

-- B2. asking for a reading: a source read by codes needs no model and no entry marker, and is not limited in pages or per day
CREATE OR REPLACE FUNCTION watch.fn_read_run_request(p_issue_id uuid, p_model text, p_token_cap bigint DEFAULT 3000000, p_from_page integer DEFAULT NULL, p_to_page integer DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_model text := NULLIF(btrim(left(p_model, 80)), ''); i record;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  SELECT x.id, x.published_on, s.registry_id, COALESCE(s.fetch_spec -> 'read' ->> 'entry_start', s.fetch_spec -> 'read' ->> 'entry_marker') AS marker,
         COALESCE(s.fetch_spec -> 'read' ->> 'method', '') = 'codes' AS by_codes INTO i
    FROM watch.publication_issue x JOIN watch.publication_source s ON s.id = x.source_id
   WHERE x.id = p_issue_id AND x.object_key IS NOT NULL;
  IF i.id IS NULL THEN RAISE EXCEPTION 'no such stored issue' USING ERRCODE = 'P0002'; END IF;
  -- a bulletin read by its printed codes asks no AI reader: no model, no size ceiling to choose, no daily limit
  IF i.by_codes THEN v_model := 'rules'; END IF;
  IF v_model IS NULL OR v_model !~ '^[a-z0-9.-]+$' THEN RAISE EXCEPTION 'a model is required' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM watch.reuse_register r WHERE r.registry_id = i.registry_id AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow processing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  IF (p_from_page IS NULL) <> (p_to_page IS NULL) OR p_from_page < 1 OR p_to_page < p_from_page OR (NOT i.by_codes AND p_to_page - p_from_page + 1 > 400) THEN
    RAISE EXCEPTION 'give both a first and a last page, at most 400 pages' USING ERRCODE = '22023';
  END IF;
  -- the registry's layout must be entered to cut an issue into its entries; without it only a few pages can be read at a time
  IF NOT i.by_codes AND i.marker IS NULL AND (p_from_page IS NULL OR p_to_page - p_from_page + 1 > 12) THEN
    RAISE EXCEPTION 'the layout of this registry''s bulletin is not entered yet' USING ERRCODE = '55000';
  END IF;
  -- a published mark is stored under its publication date
  IF i.published_on IS NULL THEN RAISE EXCEPTION 'the issue has no publication date' USING ERRCODE = '22004'; END IF;
  IF EXISTS (SELECT 1 FROM watch.read_run r WHERE r.issue_id = p_issue_id AND r.status IN ('queued', 'reading')) THEN
    RAISE EXCEPTION 'this issue is already being read' USING ERRCODE = '23505';
  END IF;
  IF NOT i.by_codes AND (SELECT count(*) FROM watch.read_run WHERE created_at > now() - interval '24 hours' AND model <> 'rules') >= 6 THEN
    RAISE EXCEPTION 'too many full readings in the last day' USING ERRCODE = '54000';
  END IF;
  INSERT INTO watch.read_run (issue_id, model, requested_by, token_cap, from_page, to_page)
  VALUES (p_issue_id, v_model, platform.current_user_id(), least(20000000, greatest(100000, COALESCE(p_token_cap, 3000000))), p_from_page, p_to_page)
  RETURNING id INTO v_id;
  PERFORM platform.enqueue_job('watch.read_run', jsonb_build_object('id', v_id, 'step', 0), now(), 'watch.read_run:' || v_id || ':0');
  RETURN v_id;
END $$;

-- B3. the page(s) of a mark are cut out of a large issue when a reviewer opens it, not for every mark beforehand
CREATE FUNCTION watch.fn_mark_pages_request(p_issue_id uuid, p_mark_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NOT watch.fn_is_reviewer() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM watch.published_mark m WHERE m.issue_id = p_issue_id AND m.id = p_mark_id AND m.extraction ->> 'page' ~ '^[0-9]+$' AND NOT (m.extraction ? 'page_key')) THEN RETURN; END IF;
  PERFORM platform.enqueue_job('watch.mark_pages', jsonb_build_object('issue_id', p_issue_id, 'from_mark', p_mark_id, 'limit', 25), now(), 'watch.mark_pages:' || p_issue_id || ':' || p_mark_id, 50::smallint);
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_mark_pages_request(uuid, uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_mark_pages_request(uuid, uuid) TO meesam_staff, meesam_admin;

-- C. Translation rules, second version (Founder, 22 Nov 2026: the Arabic translation of names was not accurate):
--    goods and services are translated; a name or address is left as printed. A translation made under the first
--    rules is not shown; it is made again when the mark is opened, and for alerts already raised.
CREATE OR REPLACE FUNCTION watch.trg_alert_translate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, platform, public, pg_temp AS $$
DECLARE m record; l record;
BEGIN
  SELECT pm.id, pm.issue_id, pm.extraction INTO m FROM watch.candidate c JOIN watch.published_mark pm ON pm.id = c.published_mark_id AND pm.registry_id = NEW.registry_id WHERE c.id = NEW.candidate_id;
  IF m.id IS NULL THEN RETURN NULL; END IF;
  FOR l IN SELECT DISTINCT left(u.locale::text, 2) AS lang FROM core.app_user u WHERE u.account_id = NEW.account_id AND u.status = 'active' LOOP
    IF l.lang ~ '^[a-z]{2}$' AND COALESCE(m.extraction -> 't' -> l.lang ->> 'rules', '') <> '2' THEN
      PERFORM platform.enqueue_job('watch.translate', jsonb_build_object('issue_id', m.issue_id, 'mark_id', m.id, 'lang', l.lang), now(), 'watch.translate:' || m.id || ':' || l.lang);
    END IF;
  END LOOP;
  RETURN NULL;
END $$;
SELECT platform.enqueue_job('watch.translate', jsonb_build_object('issue_id', pm.issue_id, 'mark_id', pm.id, 'lang', x.lang), now(), 'watch.translate:' || pm.id || ':' || x.lang)
  FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id JOIN watch.published_mark pm ON pm.id = c.published_mark_id AND pm.registry_id = a.registry_id,
       LATERAL (SELECT DISTINCT left(u.locale::text, 2) AS lang FROM core.app_user u WHERE u.account_id = a.account_id AND u.status = 'active') x
 WHERE x.lang ~ '^[a-z]{2}$' AND COALESCE(pm.extraction -> 't' -> x.lang ->> 'rules', '') <> '2';

COMMIT;
