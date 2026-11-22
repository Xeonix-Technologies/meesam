-- 0079 — The watch after the first real case (Founder rulings, 22 Nov 2026; they replace the class gate and the three
-- bands of MSM-PRD-02 Sections 6 and 7, and ruling R6 on the related-class weight).
-- Tested case: "ORO LABS" (class 32) published in the UAE against "oro selekt" (class 35) scored 51% and was not kept.
-- 1. A shared whole word counts: 80% when it is the first word of both marks, 70% otherwise (three letters or more).
-- 2. Small words in front of or inside a name are skipped ("La", "The", "ال" …): the list is a setting.
-- 3. The class is information, not a gate: every match is kept whatever its class; the alert states whether a class
--    is shared and the reader decides. Related classes are no longer needed.
-- 4. Four bands: Very high 90–100, High 80–89, Medium 60–79, Low 40–59; under 40 is not kept. Very high, High and
--    Medium raise an alert with an e-mail; Low is listed on the trademark's page only.
-- All figures are settings (watch.engine_config, watch.threshold), to be tuned from the agencies' feedback.
BEGIN;

ALTER TABLE watch.threshold ADD COLUMN band_very_high numeric(4,3) NULL;
INSERT INTO watch.threshold (scope, scope_id, version, floor, band_medium, band_high, band_very_high)
  SELECT 'global', NULL, COALESCE(max(version), 0) + 1, 0.40, 0.60, 0.80, 0.90 FROM watch.threshold WHERE scope = 'global';
-- an older row has no fourth band: there, Very high is never reached
UPDATE watch.threshold SET band_very_high = 1.001 WHERE band_very_high IS NULL;
ALTER TABLE watch.threshold ALTER COLUMN band_very_high SET NOT NULL;

INSERT INTO watch.engine_config (version, engine, rules) VALUES
  (2, 'text-2', '{"weights": {"phonetic": 0.9, "cross_script": 0.85, "contained": 0.85, "shared_first_word": 0.8, "shared_word": 0.7},
                  "skip_words": {"en": ["the", "a", "an", "and", "of", "la", "le", "les", "el", "los", "las", "il", "lo", "de", "du", "di", "der", "die", "das"], "ar": ["و"], "ar_prefix": "ال"},
                  "low_list_per_issue": 20, "backfill_days_when_period_unknown": 90, "alert_reminder_days": [10, 3]}');

-- A normalised name without the words that are skipped; a name made only of such words is kept as it is.
CREATE FUNCTION watch.fn_significant(p text, p_skip jsonb, p_prefix text DEFAULT NULL) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(NULLIF((
    SELECT string_agg(w2, ' ' ORDER BY ord)
      FROM (SELECT ord, CASE WHEN p_prefix IS NOT NULL AND left(w, char_length(p_prefix)) = p_prefix AND char_length(w) >= char_length(p_prefix) + 3
                             THEN substr(w, char_length(p_prefix) + 1) ELSE w END AS w2
              FROM unnest(string_to_array(COALESCE(p, ''), ' ')) WITH ORDINALITY AS x(w, ord)
             WHERE w <> '' AND NOT (COALESCE(p_skip, '[]'::jsonb) ? w)) y), ''), NULLIF(btrim(p), ''))
$$;

-- The text-family scores of two marks. p_rules is the engine setting (weights and skipped words); the bare weights
-- of the first engine are still accepted.
CREATE OR REPLACE FUNCTION watch.fn_text_match(a jsonb, b jsonb, w jsonb, OUT score_text numeric, OUT score_phonetic numeric, OUT score_cross numeric, OUT best numeric, OUT reasons jsonb)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE wt jsonb := COALESCE(w -> 'weights', w); sk jsonb := w -> 'skip_words';
        a_en text := watch.fn_significant(watch.fn_strip_entity(a ->> 'en'), sk -> 'en'); a_ar text := watch.fn_significant(watch.fn_strip_entity(a ->> 'ar'), sk -> 'ar', sk ->> 'ar_prefix');
        b_en text := watch.fn_significant(watch.fn_strip_entity(b ->> 'en'), sk -> 'en'); b_ar text := watch.fn_significant(watch.fn_strip_entity(b ->> 'ar'), sk -> 'ar', sk ->> 'ar_prefix');
        ka_en text := watch.fn_phonetic_key(a_en, NULL); ka_ar text := watch.fn_phonetic_key(NULL, a_ar);
        kb_en text := watch.fn_phonetic_key(b_en, NULL); kb_ar text := watch.fn_phonetic_key(NULL, b_ar);
        s_en numeric := watch.fn_sim(a_en, b_en); s_ar numeric := watch.fn_sim(a_ar, b_ar);
        c_en boolean := watch.fn_contained(a_en, b_en); c_ar boolean := watch.fn_contained(a_ar, b_ar);
        wc numeric := COALESCE((wt ->> 'contained')::numeric, 0.85); wp numeric := COALESCE((wt ->> 'phonetic')::numeric, 0.9); wx numeric := COALESCE((wt ->> 'cross_script')::numeric, 0.85);
        wf numeric := (wt ->> 'shared_first_word')::numeric; ws numeric := (wt ->> 'shared_word')::numeric;
        p_en numeric; p_ar numeric; x1 numeric; x2 numeric; r jsonb := '[]'::jsonb; sh numeric; sh_word text; sh_first boolean; sh_script text; z record;
  ok CONSTANT integer := 3;
BEGIN
  IF char_length(COALESCE(ka_en, '')) >= ok AND char_length(COALESCE(kb_en, '')) >= ok THEN p_en := watch.fn_sim(ka_en, kb_en); END IF;
  IF char_length(COALESCE(ka_ar, '')) >= ok AND char_length(COALESCE(kb_ar, '')) >= ok THEN p_ar := watch.fn_sim(ka_ar, kb_ar); END IF;
  IF char_length(COALESCE(ka_en, '')) >= ok AND char_length(COALESCE(kb_ar, '')) >= ok THEN x1 := watch.fn_sim(ka_en, kb_ar); END IF;
  IF char_length(COALESCE(ka_ar, '')) >= ok AND char_length(COALESCE(kb_en, '')) >= ok THEN x2 := watch.fn_sim(ka_ar, kb_en); END IF;
  -- a whole word of three letters or more that both marks carry; stronger when it is the first word of both
  IF wf IS NOT NULL OR ws IS NOT NULL THEN
    FOR z IN SELECT * FROM (VALUES ('en', a_en, b_en), ('ar', a_ar, b_ar)) v(script, x, y) WHERE v.x IS NOT NULL AND v.y IS NOT NULL AND v.x <> v.y LOOP
      IF split_part(z.x, ' ', 1) = split_part(z.y, ' ', 1) AND char_length(split_part(z.x, ' ', 1)) >= 3 THEN
        IF COALESCE(sh, 0) < COALESCE(wf, 0) THEN sh := wf; sh_word := split_part(z.x, ' ', 1); sh_first := true; sh_script := z.script; END IF;
      ELSIF ws IS NOT NULL AND COALESCE(sh, 0) < ws THEN
        SELECT t INTO sh_word FROM unnest(string_to_array(z.x, ' ')) t WHERE char_length(t) >= 3 AND t = ANY (string_to_array(z.y, ' ')) ORDER BY char_length(t) DESC LIMIT 1;
        IF sh_word IS NOT NULL THEN sh := ws; sh_first := false; sh_script := z.script; END IF;
      END IF;
    END LOOP;
  END IF;
  score_text := greatest(s_en, s_ar, CASE WHEN c_en THEN wc END, CASE WHEN c_ar THEN wc END, sh);
  score_phonetic := greatest(p_en, p_ar);
  score_cross := greatest(x1, x2);
  best := COALESCE(greatest(score_text, score_phonetic * wp, score_cross * wx), 0);
  IF s_en = 1 THEN r := r || '[{"code":"same_text","script":"en"}]'::jsonb; ELSIF s_en >= 0.7 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'similar_text', 'script', 'en', 'score', s_en)); END IF;
  IF s_ar = 1 THEN r := r || '[{"code":"same_text","script":"ar"}]'::jsonb; ELSIF s_ar >= 0.7 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'similar_text', 'script', 'ar', 'score', s_ar)); END IF;
  IF c_en THEN r := r || '[{"code":"contained","script":"en"}]'::jsonb; END IF;
  IF c_ar THEN r := r || '[{"code":"contained","script":"ar"}]'::jsonb; END IF;
  IF sh IS NOT NULL AND NOT (c_en OR c_ar) THEN
    r := r || jsonb_build_array(jsonb_build_object('code', CASE WHEN sh_first THEN 'shared_first_word' ELSE 'shared_word' END, 'script', sh_script, 'word', sh_word));
  END IF;
  IF p_en >= 0.8 AND COALESCE(s_en, 0) < 1 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'sounds_alike', 'script', 'en', 'score', p_en)); END IF;
  IF p_ar >= 0.8 AND COALESCE(s_ar, 0) < 1 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'sounds_alike', 'script', 'ar', 'score', p_ar)); END IF;
  IF score_cross >= 0.8 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'sounds_alike_cross', 'score', score_cross)); END IF;
  reasons := r;
END $$;

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
    v_own := EXISTS (SELECT 1 FROM watch.record_match x WHERE x.record_id = r.id AND x.mark_id = m.id)
          OR (m.applicant_name IS NOT NULL AND r.owner_name IS NOT NULL AND (
                watch.fn_strip_entity(watch.fn_normalise_latin(m.applicant_name)) IN (watch.fn_strip_entity(watch.fn_normalise_latin(r.owner_name ->> 'en')), watch.fn_strip_entity(watch.fn_normalise_latin(r.owner_name ->> 'ar')))
             OR watch.fn_strip_entity(watch.fn_normalise_arabic(m.applicant_name)) IN (watch.fn_strip_entity(watch.fn_normalise_arabic(r.owner_name ->> 'ar')), watch.fn_strip_entity(watch.fn_normalise_arabic(r.owner_name ->> 'en')))));
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

-- The e-mail about new alerts counts the two top bands together.
CREATE OR REPLACE FUNCTION watch.fn_alert_mails_take()
RETURNS TABLE (email text, name text, locale text, account_id uuid, kind text, alerts integer, high integer, nearest_deadline date, days_left integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
BEGIN
  RETURN QUERY
  WITH fresh AS (
    UPDATE watch.alert a SET mailed_at = now() WHERE a.mailed_at IS NULL RETURNING a.account_id, a.risk_band, a.opposition_deadline
  ), grouped AS (
    SELECT f.account_id, count(*)::int AS n, (count(*) FILTER (WHERE f.risk_band IN ('very_high', 'high')))::int AS high, min(f.opposition_deadline) AS nearest FROM fresh f GROUP BY f.account_id
  )
  SELECT u.email::text, u.name, u.locale::text, g.account_id, 'new'::text, g.n, g.high, g.nearest, (g.nearest - current_date)::int
    FROM grouped g JOIN core.app_user u ON u.account_id = g.account_id AND u.status = 'active';

  RETURN QUERY
  WITH steps AS (
    SELECT a.id, a.account_id, a.risk_band, a.opposition_deadline, cardinality(a.reminded_at) AS sent,
           COALESCE((registry.fn_current_profile(a.registry_id)).rules -> 'watch_alert_reminders_days',
                    (SELECT c.rules -> 'alert_reminder_days' FROM watch.engine_config c WHERE c.effective_from <= current_date ORDER BY c.version DESC LIMIT 1)) AS days
      FROM watch.alert a WHERE a.status = 'new' AND a.opposition_deadline IS NOT NULL AND a.opposition_deadline >= current_date
  ), due AS (
    SELECT s.id, s.account_id, s.risk_band, s.opposition_deadline FROM steps s
     WHERE s.sent < jsonb_array_length(COALESCE(s.days, '[]'::jsonb)) AND (s.opposition_deadline - current_date) <= (s.days ->> s.sent)::int
  ), marked AS (
    UPDATE watch.alert a SET reminded_at = a.reminded_at || now() FROM due d WHERE d.id = a.id RETURNING d.account_id, d.risk_band, d.opposition_deadline
  ), grouped AS (
    SELECT m.account_id, count(*)::int AS n, (count(*) FILTER (WHERE m.risk_band IN ('very_high', 'high')))::int AS high, min(m.opposition_deadline) AS nearest FROM marked m GROUP BY m.account_id
  )
  SELECT u.email::text, u.name, u.locale::text, g.account_id, 'reminder'::text, g.n, g.high, g.nearest, (g.nearest - current_date)::int
    FROM grouped g JOIN core.app_user u ON u.account_id = g.account_id AND u.status = 'active';
END $$;

-- Low matches (40 to 59) raise no alert; the account that holds the trademark sees them listed on the trademark's
-- page: for each issue the closest ones only (same class first), up to the number in the engine setting.
-- Shown only where the re-use register allows showing the registry's data; the account's own publications are left out.
CREATE FUNCTION watch.fn_other_matches(p_record_id uuid)
RETURNS TABLE (registry_code text, issue_no text, published_on date, pub_text jsonb, pub_no text, pub_classes smallint[], applicant_name text, score numeric, class_kind text, reasons jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
  WITH cap AS (SELECT COALESCE((SELECT (c.rules ->> 'low_list_per_issue')::int FROM watch.engine_config c WHERE c.effective_from <= current_date ORDER BY c.version DESC LIMIT 1), 20) AS n),
  ranked AS (
    SELECT g.code::text AS registry_code, i.issue_no, m.publication_date, m.mark_text, m.application_no, m.classes, m.applicant_name, c.score, c.explanation ->> 'class' AS class_kind,
           COALESCE(c.explanation -> 'reasons', '[]'::jsonb) AS reasons,
           row_number() OVER (PARTITION BY m.issue_id ORDER BY (c.explanation ->> 'class' = 'same') DESC, c.score DESC, m.id) AS k
      FROM watch.candidate c
      JOIN watch.published_mark m ON m.id = c.published_mark_id
      JOIN watch.publication_issue i ON i.id = m.issue_id
      JOIN registry.registry g ON g.id = m.registry_id
      JOIN watch.reuse_register u ON u.registry_id = m.registry_id AND u.may_show IS TRUE
     WHERE c.record_id = p_record_id AND c.explanation ->> 'band' = 'low' AND NOT COALESCE((c.explanation ->> 'own')::boolean, false)
       AND core.fn_can_access(p_record_id, platform.current_account_id(), false))
  SELECT r.registry_code, r.issue_no, r.publication_date, r.mark_text, r.application_no, r.classes, r.applicant_name, r.score, r.class_kind, r.reasons
    FROM ranked r, cap WHERE r.k <= cap.n
   ORDER BY r.publication_date DESC, (r.class_kind = 'same') DESC, r.score DESC LIMIT 100
$$;
REVOKE EXECUTE ON FUNCTION watch.fn_other_matches(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION watch.fn_other_matches(uuid) TO meesam_app;

-- every verified mark is compared again under the new rules
SELECT platform.enqueue_job('watch.compare_registry', jsonb_build_object('registry_id', x.registry_id), now(), 'watch.compare_registry:' || x.registry_id)
  FROM (SELECT DISTINCT registry_id FROM watch.published_mark WHERE verify_state <> 'ai_extracted') x;

COMMIT;
