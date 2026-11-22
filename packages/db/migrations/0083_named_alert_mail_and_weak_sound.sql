-- 0083 — Founder rulings, 22 Nov 2026, from the alerts of Türkiye's bulletin 504 against "oro selekt":
--  1. The alert e-mail names the marks: each published mark, its registry, the likeness and whether a class is shared.
--  2. A weak likeness with no shared word is Low: listed on the trademark's Watch tab, no alert and no e-mail.
--     Ruled as "a sound-only match below 80% becomes Low". On checking, "er pelet" against "oro selekt" (60%) came
--     from spelling, not sound (four letters apart in ten). So the same rule is applied to both: sound alone alerts
--     from 80% alike, spelling alone from 70% alike; under that a match is capped at 59%. The figures are settings.
--     RULING NEEDED: confirm 70% for spelling alone (it also makes "SEESAW" against "MEESAM", 67%, Low).
-- And a match is never shown without its reason.
BEGIN;

INSERT INTO watch.engine_config (version, engine, rules)
  SELECT max(version) + 1, (array_agg(engine ORDER BY version DESC))[1], (array_agg(rules ORDER BY version DESC))[1] || '{"sound_alert_min": 0.8, "spelling_alert_min": 0.7, "weak_cap": 0.59}'::jsonb FROM watch.engine_config;

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
        -- a likeness of sound alone alerts only when the sound is at least this close; under it, it is capped (listed, no alert)
        smin numeric := COALESCE((w ->> 'sound_alert_min')::numeric, 0); scap numeric := COALESCE((w ->> 'weak_cap')::numeric, 1); v_sound numeric;
        pmin numeric := COALESCE((w ->> 'spelling_alert_min')::numeric, 0); v_spell numeric;
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
  -- spelling alone (no shared word, neither wording inside the other): under the least likeness that alerts, it is capped
  v_spell := greatest(s_en, s_ar);
  IF v_spell IS NOT NULL AND v_spell < pmin THEN v_spell := least(v_spell, scap); END IF;
  score_text := greatest(v_spell, CASE WHEN c_en THEN wc END, CASE WHEN c_ar THEN wc END, sh);
  score_phonetic := greatest(p_en, p_ar);
  score_cross := greatest(x1, x2);
  v_sound := greatest(CASE WHEN score_phonetic IS NULL THEN NULL WHEN score_phonetic >= smin THEN score_phonetic * wp ELSE least(score_phonetic * wp, scap) END,
                      CASE WHEN score_cross IS NULL THEN NULL WHEN score_cross >= smin THEN score_cross * wx ELSE least(score_cross * wx, scap) END);
  best := COALESCE(greatest(score_text, v_sound), 0);
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
  -- a match is never left without its reason: a weaker likeness says what it rests on
  IF r = '[]'::jsonb AND best > 0 THEN
    IF COALESCE(score_text, 0) >= COALESCE(v_sound, 0) THEN
      r := jsonb_build_array(jsonb_build_object('code', 'similar_text', 'script', CASE WHEN COALESCE(s_ar, 0) > COALESCE(s_en, 0) THEN 'ar' ELSE 'en' END, 'score', greatest(s_en, s_ar)));
    ELSIF COALESCE(score_cross, 0) * wx > COALESCE(score_phonetic, 0) * wp THEN
      r := jsonb_build_array(jsonb_build_object('code', 'sounds_alike_cross', 'score', score_cross, 'weak', true));
    ELSE
      r := jsonb_build_array(jsonb_build_object('code', 'sounds_alike', 'script', CASE WHEN COALESCE(p_ar, 0) > COALESCE(p_en, 0) THEN 'ar' ELSE 'en' END, 'score', score_phonetic, 'weak', true));
    END IF;
  END IF;
  reasons := r;
END $$;

DROP FUNCTION watch.fn_alert_mails_take();
CREATE FUNCTION watch.fn_alert_mails_take()
RETURNS TABLE (email text, name text, locale text, account_id uuid, kind text, alerts integer, high integer, nearest_deadline date, days_left integer, items jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
BEGIN
  RETURN QUERY
  WITH fresh AS (
    UPDATE watch.alert a SET mailed_at = now() WHERE a.mailed_at IS NULL RETURNING a.id, a.account_id, a.risk_band, a.opposition_deadline
  ), grouped AS (
    SELECT f.account_id, count(*)::int AS n, (count(*) FILTER (WHERE f.risk_band IN ('very_high', 'high')))::int AS high, min(f.opposition_deadline) AS nearest, array_agg(f.id) AS ids FROM fresh f GROUP BY f.account_id
  )
  SELECT u.email::text, u.name, u.locale::text, g.account_id, 'new'::text, g.n, g.high, g.nearest, (g.nearest - current_date)::int,
         (SELECT jsonb_agg(x.item ORDER BY x.score DESC) FROM (
             SELECT jsonb_build_object('mark', COALESCE(pm.mark_text ->> 'en', pm.mark_text ->> 'ar'), 'registry', rg.code, 'score', round(c.score * 100), 'band', a.risk_band,
                                       'same_class', c.explanation ->> 'class' = 'same', 'classes', to_jsonb(pm.classes)) AS item, c.score
               FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id JOIN watch.published_mark pm ON pm.id = c.published_mark_id AND pm.registry_id = a.registry_id
               JOIN registry.registry rg ON rg.id = a.registry_id
              WHERE a.id = ANY (g.ids) ORDER BY c.score DESC LIMIT 12) x)
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
    UPDATE watch.alert a SET reminded_at = a.reminded_at || now() FROM due d WHERE d.id = a.id RETURNING d.id, d.account_id, d.risk_band, d.opposition_deadline
  ), grouped AS (
    SELECT m.account_id, count(*)::int AS n, (count(*) FILTER (WHERE m.risk_band IN ('very_high', 'high')))::int AS high, min(m.opposition_deadline) AS nearest, array_agg(m.id) AS ids FROM marked m GROUP BY m.account_id
  )
  SELECT u.email::text, u.name, u.locale::text, g.account_id, 'reminder'::text, g.n, g.high, g.nearest, (g.nearest - current_date)::int,
         (SELECT jsonb_agg(x.item ORDER BY x.score DESC) FROM (
             SELECT jsonb_build_object('mark', COALESCE(pm.mark_text ->> 'en', pm.mark_text ->> 'ar'), 'registry', rg.code, 'score', round(c.score * 100), 'band', a.risk_band,
                                       'same_class', c.explanation ->> 'class' = 'same', 'classes', to_jsonb(pm.classes)) AS item, c.score
               FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id JOIN watch.published_mark pm ON pm.id = c.published_mark_id AND pm.registry_id = a.registry_id
               JOIN registry.registry rg ON rg.id = a.registry_id
              WHERE a.id = ANY (g.ids) ORDER BY c.score DESC LIMIT 12) x)
    FROM grouped g JOIN core.app_user u ON u.account_id = g.account_id AND u.status = 'active';
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_alert_mails_take() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_alert_mails_take() TO meesam_worker;

-- An alert raised under the earlier rule for a match that is now Low is withdrawn if nobody has acted on it yet,
-- and every verified mark is compared again so its match carries the new score and reason.
CREATE FUNCTION watch.fn_alerts_settle() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  WITH gone AS (DELETE FROM watch.alert a USING watch.candidate c WHERE c.id = a.candidate_id AND a.status = 'new' AND c.explanation ->> 'band' = 'low' RETURNING a.id)
  SELECT count(*)::int INTO n FROM gone;
  DELETE FROM platform.notification x WHERE x.kind = 'alert_new' AND NOT EXISTS (SELECT 1 FROM watch.alert a WHERE a.id::text = x.payload ->> 'alert_id');
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_alerts_settle() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_alerts_settle() TO meesam_worker;
SELECT platform.enqueue_job('watch.compare_issue', jsonb_build_object('issue_id', x.issue_id), now(), 'watch.compare_issue:' || x.issue_id)
  FROM (SELECT DISTINCT issue_id FROM watch.published_mark WHERE verify_state <> 'ai_extracted') x;

COMMIT;
