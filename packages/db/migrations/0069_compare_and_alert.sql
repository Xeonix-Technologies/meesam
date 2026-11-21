-- 0069 — Compare and alert, first engine (plan item A4; MSM-PRD-02 Sections 6 to 8; Founder ruling R6, 21 Nov 2026).
-- A published mark that a person has verified is compared with every watched trademark of its registry. The first
-- engine ("text-1") scores the text family only: spelling (per script, entity terms stripped), sound (the consonant
-- skeleton of 0001, per script) and cross-script sound (Arabic against Latin). The strongest of the three counts in
-- full; the class is a gate and a weight: same class 1, related class 0.75 (R6), no shared or related class = outside
-- the classes. High and Medium create an alert per account that holds the trademark; Low is kept as a match only;
-- a match outside the classes is kept only at High and raises no alert.
-- Not in this engine (they need the embeddings service and the mark pictures): meaning, image, goods wording.
-- Rules kept: alerts are per registry and per account, never merged; an unverified mark is never compared; the
-- deadline comes from the registry profile and only where it is verified; the wording of reasons is descriptive.
-- The re-use register decides: nothing is compared where "derive" is refused, and an alert (which shows the
-- published mark to an account) is raised only where "show" is allowed.
BEGIN;

-- Engine settings are configuration, versioned; a new setting is a new version.
CREATE TABLE watch.engine_config (
  version        integer PRIMARY KEY,
  engine         text NOT NULL,
  effective_from date NOT NULL DEFAULT current_date,
  rules          jsonb NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE watch.engine_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY engine_config_read ON watch.engine_config FOR SELECT TO meesam_staff, meesam_admin, meesam_worker USING (true);
GRANT SELECT ON watch.engine_config TO meesam_staff, meesam_admin, meesam_worker;
-- RULING NEEDED: the weights of sound, cross-script sound and "one mark contained in the other" are an engineering
-- starting point (PRD: fusion and thresholds Proposed), to be tuned from alert feedback. related_class is ruled (R6).
INSERT INTO watch.engine_config (version, engine, rules) VALUES
  (1, 'text-1', '{"weights": {"phonetic": 0.9, "cross_script": 0.85, "contained": 0.85, "related_class": 0.75}, "backfill_days_when_period_unknown": 90, "alert_reminder_days": [10, 3]}');

-- Edit distance between two short strings (marks are short; no extension is needed).
CREATE FUNCTION watch.fn_lev(a text, b text) RETURNS integer LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s text := left(COALESCE(a, ''), 80); t text := left(COALESCE(b, ''), 80); n integer := char_length(s); m integer := char_length(t);
  prev integer[]; cur integer[]; i integer; j integer; c integer;
BEGIN
  IF n = 0 THEN RETURN m; END IF;
  IF m = 0 THEN RETURN n; END IF;
  FOR j IN 0..m LOOP prev[j + 1] := j; END LOOP;
  FOR i IN 1..n LOOP
    cur[1] := i;
    FOR j IN 1..m LOOP
      c := CASE WHEN substr(s, i, 1) = substr(t, j, 1) THEN 0 ELSE 1 END;
      cur[j + 1] := least(prev[j + 1] + 1, cur[j] + 1, prev[j] + c);
    END LOOP;
    prev := cur;
  END LOOP;
  RETURN prev[m + 1];
END $$;

-- Likeness of two strings from 0 to 1; NULL when either is missing.
CREATE FUNCTION watch.fn_sim(a text, b text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN NULLIF(a, '') IS NULL OR NULLIF(b, '') IS NULL THEN NULL
              ELSE round(1 - watch.fn_lev(a, b)::numeric / greatest(char_length(left(a, 80)), char_length(left(b, 80))), 4) END
$$;

-- A normalised name without the words that only state the legal form (PRD Section 6). A name made only of such words is kept.
CREATE FUNCTION watch.fn_strip_entity(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(NULLIF(btrim(regexp_replace(regexp_replace(' ' || COALESCE(p, '') || ' ',
           '\m(co|company|corp|corporation|inc|incorporated|llc|ltd|limited|plc|gmbh|fze|fzco|fzc|wll|est|establishment)\M|(^|\s)(شركه|موسسه|المحدوده|ذ م م|ش ذ م م|ذمم|ش م م)(?=\s|$)', ' ', 'g'),
           '\s+', ' ', 'g')), ''), NULLIF(btrim(p), ''))
$$;

-- True when every word of the shorter name is a word of the longer one (and they are not the same name).
CREATE FUNCTION watch.fn_contained(a text, b text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN NULLIF(a, '') IS NULL OR NULLIF(b, '') IS NULL OR a = b THEN false ELSE (
    WITH x AS (SELECT string_to_array(a, ' ') AS wa, string_to_array(b, ' ') AS wb),
         y AS (SELECT CASE WHEN cardinality(wa) <= cardinality(wb) THEN wa ELSE wb END AS short, CASE WHEN cardinality(wa) <= cardinality(wb) THEN wb ELSE wa END AS long FROM x)
    SELECT short <@ long AND cardinality(short) < cardinality(long) AND EXISTS (SELECT 1 FROM unnest(short) w WHERE char_length(w) >= 3) FROM y) END
$$;

-- The text-family scores of two marks (normalised wording per script, as stored in mark_text_norm).
CREATE FUNCTION watch.fn_text_match(a jsonb, b jsonb, w jsonb, OUT score_text numeric, OUT score_phonetic numeric, OUT score_cross numeric, OUT best numeric, OUT reasons jsonb)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE a_en text := watch.fn_strip_entity(a ->> 'en'); a_ar text := watch.fn_strip_entity(a ->> 'ar');
        b_en text := watch.fn_strip_entity(b ->> 'en'); b_ar text := watch.fn_strip_entity(b ->> 'ar');
        ka_en text := watch.fn_phonetic_key(a_en, NULL); ka_ar text := watch.fn_phonetic_key(NULL, a_ar);
        kb_en text := watch.fn_phonetic_key(b_en, NULL); kb_ar text := watch.fn_phonetic_key(NULL, b_ar);
        s_en numeric := watch.fn_sim(a_en, b_en); s_ar numeric := watch.fn_sim(a_ar, b_ar);
        c_en boolean := watch.fn_contained(a_en, b_en); c_ar boolean := watch.fn_contained(a_ar, b_ar);
        wc numeric := COALESCE((w ->> 'contained')::numeric, 0.85); wp numeric := COALESCE((w ->> 'phonetic')::numeric, 0.9); wx numeric := COALESCE((w ->> 'cross_script')::numeric, 0.85);
        p_en numeric; p_ar numeric; x1 numeric; x2 numeric; r jsonb := '[]'::jsonb;
  -- a skeleton of fewer than three letters says too little about how a name sounds
  ok CONSTANT integer := 3;
BEGIN
  IF char_length(COALESCE(ka_en, '')) >= ok AND char_length(COALESCE(kb_en, '')) >= ok THEN p_en := watch.fn_sim(ka_en, kb_en); END IF;
  IF char_length(COALESCE(ka_ar, '')) >= ok AND char_length(COALESCE(kb_ar, '')) >= ok THEN p_ar := watch.fn_sim(ka_ar, kb_ar); END IF;
  IF char_length(COALESCE(ka_en, '')) >= ok AND char_length(COALESCE(kb_ar, '')) >= ok THEN x1 := watch.fn_sim(ka_en, kb_ar); END IF;
  IF char_length(COALESCE(ka_ar, '')) >= ok AND char_length(COALESCE(kb_en, '')) >= ok THEN x2 := watch.fn_sim(ka_ar, kb_en); END IF;
  score_text := greatest(s_en, s_ar, CASE WHEN c_en THEN wc END, CASE WHEN c_ar THEN wc END);
  score_phonetic := greatest(p_en, p_ar);
  score_cross := greatest(x1, x2);
  best := COALESCE(greatest(score_text, score_phonetic * wp, score_cross * wx), 0);
  -- reasons, as codes the pages turn into plain descriptive sentences in the reader's language
  IF s_en = 1 THEN r := r || '[{"code":"same_text","script":"en"}]'::jsonb; ELSIF s_en >= 0.7 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'similar_text', 'script', 'en', 'score', s_en)); END IF;
  IF s_ar = 1 THEN r := r || '[{"code":"same_text","script":"ar"}]'::jsonb; ELSIF s_ar >= 0.7 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'similar_text', 'script', 'ar', 'score', s_ar)); END IF;
  IF c_en THEN r := r || '[{"code":"contained","script":"en"}]'::jsonb; END IF;
  IF c_ar THEN r := r || '[{"code":"contained","script":"ar"}]'::jsonb; END IF;
  IF p_en >= 0.8 AND COALESCE(s_en, 0) < 1 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'sounds_alike', 'script', 'en', 'score', p_en)); END IF;
  IF p_ar >= 0.8 AND COALESCE(s_ar, 0) < 1 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'sounds_alike', 'script', 'ar', 'score', p_ar)); END IF;
  IF score_cross >= 0.8 THEN r := r || jsonb_build_array(jsonb_build_object('code', 'sounds_alike_cross', 'score', score_cross)); END IF;
  reasons := r;
END $$;

-- Is the trademark in the watch? (PRD Section 9: on payment, or while the pilot is free; out when closed or unpaid read-only.)
CREATE FUNCTION core.fn_record_watched(p_record_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, public, pg_temp AS $$
  SELECT NOT r.terminal AND (r.paid_state = 'paid'
           OR (r.paid_state <> 'read_only_unpaid' AND COALESCE((SELECT (p.rules ->> 'pilot_all_free')::boolean FROM core.price_list p WHERE p.effective_from <= current_date ORDER BY p.version DESC LIMIT 1), false)))
    FROM core.record r WHERE r.id = p_record_id
$$;

-- The last day to oppose a publication of that date, where the registry's period is verified; otherwise none.
CREATE FUNCTION watch.fn_opposition_deadline(p_registry_id uuid, p_published date) RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, registry, public, pg_temp AS $$
  SELECT CASE WHEN COALESCE((p.rules #>> '{timers,oppose,verified}')::boolean, false) THEN
           CASE WHEN p.rules #>> '{timers,oppose,days}' IS NOT NULL THEN p_published + (p.rules #>> '{timers,oppose,days}')::integer
                WHEN p.rules #>> '{timers,oppose,months}' IS NOT NULL THEN (p_published + make_interval(months => (p.rules #>> '{timers,oppose,months}')::integer))::date END END
    FROM registry.fn_current_profile(p_registry_id, p_published) p
$$;

ALTER TABLE watch.alert ADD COLUMN deadline_entered_by uuid NULL REFERENCES core.app_user(id);   -- the deadline was entered by hand (period unverified)
ALTER TABLE watch.alert ADD COLUMN dismiss_reason text NULL CHECK (dismiss_reason IN ('not_similar', 'different_goods', 'same_owner', 'coexistence', 'other'));
ALTER TABLE watch.alert ADD COLUMN status_by uuid NULL REFERENCES core.app_user(id);
ALTER TABLE watch.alert ADD COLUMN mailed_at timestamptz NULL;
CREATE INDEX candidate_pair ON watch.candidate (published_mark_id, record_id);

-- One verified mark against the watched trademarks of its registry (or against one trademark). Returns alerts raised.
CREATE FUNCTION watch.fn_compare(p_registry_id uuid, p_publication_date date, p_mark_id uuid, p_record_id uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE m watch.published_mark; cfg watch.engine_config; th watch.threshold; reg registry.registry_profile; u watch.reuse_register;
        r record; t record; v_run uuid; v_cand uuid; v_overlap smallint[]; v_related boolean; v_weight numeric; v_score numeric; v_band watch.risk_band;
        v_own boolean; v_expl jsonb; v_deadline date; v_new integer := 0; a record; w jsonb; v_alert uuid; v_rc smallint[];
BEGIN
  SELECT * INTO m FROM watch.published_mark WHERE registry_id = p_registry_id AND publication_date = p_publication_date AND id = p_mark_id;
  IF m.id IS NULL OR m.verify_state = 'ai_extracted' OR m.mark_text_norm IS NULL OR m.mark_text_norm = '{}'::jsonb THEN RETURN 0; END IF;
  SELECT * INTO u FROM watch.reuse_register WHERE registry_id = m.registry_id;
  IF u.may_derive IS FALSE THEN RETURN 0; END IF;
  SELECT * INTO cfg FROM watch.engine_config WHERE effective_from <= current_date ORDER BY version DESC LIMIT 1;
  w := cfg.rules -> 'weights';
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
    -- related classes come from the registry profile's own table: {"3": [5, 44], …}; none entered = none related
    v_related := cardinality(v_overlap) = 0 AND EXISTS (
      SELECT 1 FROM unnest(v_rc) rc, unnest(m.classes) mc
       WHERE COALESCE(reg.rules -> 'related_classes' -> rc::text, '[]'::jsonb) @> to_jsonb(mc::int)
          OR COALESCE(reg.rules -> 'related_classes' -> mc::text, '[]'::jsonb) @> to_jsonb(rc::int));
    v_weight := CASE WHEN cardinality(v_overlap) > 0 THEN 1 WHEN v_related THEN COALESCE((w ->> 'related_class')::numeric, 0.75) ELSE 0 END;
    -- outside the classes: kept only when the names alone are High, and it raises no alert
    v_score := CASE WHEN v_weight = 0 THEN t.best ELSE round(t.best * v_weight, 4) END;
    CONTINUE WHEN v_weight = 0 AND t.best < th.band_high;
    CONTINUE WHEN v_weight > 0 AND v_score < th.floor;
    v_band := CASE WHEN v_score >= th.band_high THEN 'high' WHEN v_score >= th.band_medium THEN 'medium' ELSE 'low' END;
    -- the account's own publication: the same application as the trademark, or the owner's own name as applicant
    v_own := EXISTS (SELECT 1 FROM watch.record_match x WHERE x.record_id = r.id AND x.mark_id = m.id)
          OR (m.applicant_name IS NOT NULL AND r.owner_name IS NOT NULL AND (
                watch.fn_strip_entity(watch.fn_normalise_latin(m.applicant_name)) IN (watch.fn_strip_entity(watch.fn_normalise_latin(r.owner_name ->> 'en')), watch.fn_strip_entity(watch.fn_normalise_latin(r.owner_name ->> 'ar')))
             OR watch.fn_strip_entity(watch.fn_normalise_arabic(m.applicant_name)) IN (watch.fn_strip_entity(watch.fn_normalise_arabic(r.owner_name ->> 'ar')), watch.fn_strip_entity(watch.fn_normalise_arabic(r.owner_name ->> 'en')))));
    v_expl := jsonb_build_object('engine', cfg.engine, 'config', cfg.version, 'reasons', t.reasons, 'text_best', t.best, 'class_weight', v_weight,
                                 'class', CASE WHEN cardinality(v_overlap) > 0 THEN 'same' WHEN v_related THEN 'related' ELSE 'outside' END,
                                 'band', v_band, 'own', v_own, 'mark_classes', to_jsonb(m.classes), 'record_classes', to_jsonb(v_rc),
                                 'held', CASE WHEN u.may_show IS NOT TRUE THEN 'reuse_show' END);

    IF v_run IS NULL THEN
      INSERT INTO watch.comparison_run (issue_id, engine_version) VALUES (m.issue_id, cfg.engine)
      ON CONFLICT (issue_id, engine_version) WHERE issue_id IS NOT NULL DO UPDATE SET updated_at = now() RETURNING id INTO v_run;
    END IF;
    SELECT c.id INTO v_cand FROM watch.candidate c WHERE c.published_mark_id = m.id AND c.record_id = r.id AND c.run_id = v_run LIMIT 1;
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
    CONTINUE WHEN v_weight = 0 OR v_band = 'low' OR u.may_show IS NOT TRUE;
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

-- One trademark against the verified marks already published in its watched registries whose period may still be
-- open (backfill, PRD Section 9). Where the period is not verified the profile's stated period is used only to choose
-- what to compare (no deadline is shown from it); where none is stated, the configured number of days.
-- RULING NEEDED: how far back to compare where a registry's opposition period is unverified or unknown.
CREATE FUNCTION watch.fn_compare_record(p_record_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE s record; m record; n integer := 0; v_days integer; cfg watch.engine_config; p registry.registry_profile;
BEGIN
  IF NOT COALESCE(core.fn_record_watched(p_record_id), false) THEN RETURN 0; END IF;
  SELECT * INTO cfg FROM watch.engine_config WHERE effective_from <= current_date ORDER BY version DESC LIMIT 1;
  FOR s IN SELECT registry_id FROM core.record_registry_scope WHERE record_id = p_record_id LOOP
    p := registry.fn_current_profile(s.registry_id);
    v_days := COALESCE((p.rules #>> '{timers,oppose,days}')::integer, (p.rules #>> '{timers,oppose,months}')::integer * 31,
                       (cfg.rules ->> 'backfill_days_when_period_unknown')::integer, 90);
    FOR m IN SELECT x.registry_id, x.publication_date, x.id FROM watch.published_mark x
              WHERE x.registry_id = s.registry_id AND x.verify_state <> 'ai_extracted' AND x.publication_date >= current_date - v_days LOOP
      n := n + watch.fn_compare(m.registry_id, m.publication_date, m.id, p_record_id);
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

-- Every verified mark of a registry published in the last year, again (after the re-use register changes).
CREATE FUNCTION watch.fn_compare_registry(p_registry_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE m record; n integer := 0;
BEGIN
  FOR m IN SELECT x.registry_id, x.publication_date, x.id FROM watch.published_mark x
            WHERE x.registry_id = p_registry_id AND x.verify_state <> 'ai_extracted' AND x.publication_date >= current_date - 365 LOOP
    n := n + watch.fn_compare(m.registry_id, m.publication_date, m.id);
  END LOOP;
  RETURN n;
END $$;

REVOKE EXECUTE ON FUNCTION watch.fn_compare(uuid, date, uuid, uuid), watch.fn_compare_record(uuid), watch.fn_compare_registry(uuid), core.fn_record_watched(uuid),
                           watch.fn_opposition_deadline(uuid, date) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_compare(uuid, date, uuid, uuid), watch.fn_compare_record(uuid), watch.fn_compare_registry(uuid) TO meesam_worker;
GRANT EXECUTE ON FUNCTION core.fn_record_watched(uuid), watch.fn_opposition_deadline(uuid, date) TO meesam_worker, meesam_staff, meesam_admin, meesam_app;

-- When the comparing happens: the work is queued for the worker, so saving is never slowed or stopped by it.
CREATE FUNCTION watch.trg_mark_compare() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NEW.verify_state <> 'ai_extracted' THEN
    PERFORM platform.enqueue_job('watch.compare', jsonb_build_object('registry_id', NEW.registry_id, 'publication_date', NEW.publication_date, 'mark_id', NEW.id), now(), 'watch.compare:' || NEW.id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER mark_compare AFTER INSERT OR UPDATE OF verify_state, mark_text, classes, applicant_name ON watch.published_mark
  FOR EACH ROW EXECUTE FUNCTION watch.trg_mark_compare();

CREATE FUNCTION core.trg_record_compare() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, watch, platform, public, pg_temp AS $$
DECLARE v uuid := CASE WHEN TG_TABLE_NAME = 'record' THEN (to_jsonb(COALESCE(NEW, OLD)) ->> 'id')::uuid ELSE (to_jsonb(COALESCE(NEW, OLD)) ->> 'record_id')::uuid END;
BEGIN
  PERFORM platform.enqueue_job('watch.compare_record', jsonb_build_object('record_id', v), now() + interval '1 minute', 'watch.compare_record:' || v);
  RETURN NULL;
END $$;
CREATE TRIGGER record_compare AFTER INSERT OR UPDATE OF mark_text, paid_state, terminal ON core.record FOR EACH ROW EXECUTE FUNCTION core.trg_record_compare();
CREATE TRIGGER record_class_compare AFTER INSERT OR DELETE ON core.record_class FOR EACH ROW EXECUTE FUNCTION core.trg_record_compare();
CREATE TRIGGER record_scope_compare AFTER INSERT ON core.record_registry_scope FOR EACH ROW EXECUTE FUNCTION core.trg_record_compare();

CREATE FUNCTION watch.trg_reuse_compare() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, public, pg_temp AS $$
BEGIN
  IF NEW.may_show IS TRUE AND NEW.may_derive IS NOT FALSE AND (TG_OP = 'INSERT' OR OLD.may_show IS NOT TRUE OR OLD.may_derive IS FALSE) THEN
    PERFORM platform.enqueue_job('watch.compare_registry', jsonb_build_object('registry_id', NEW.registry_id), now(), 'watch.compare_registry:' || NEW.registry_id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER reuse_compare AFTER INSERT OR UPDATE OF may_show, may_derive ON watch.reuse_register FOR EACH ROW EXECUTE FUNCTION watch.trg_reuse_compare();

-- An account acts on its own alert: reviewed, opposition recorded, dismissed with a reason, or back to new.
-- Where the registry's opposition period is unverified the alert carries no deadline: the account enters it by hand
-- before the alert can be marked reviewed (PRD Section 8). Every change is audited by the table's audit trigger.
CREATE FUNCTION watch.fn_alert_set(p_alert_id uuid, p_status text, p_reason text DEFAULT NULL, p_deadline date DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, platform, public, pg_temp AS $$
DECLARE a watch.alert;
BEGIN
  SELECT * INTO a FROM watch.alert WHERE id = p_alert_id AND account_id = platform.current_account_id() FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'no such alert' USING ERRCODE = 'P0002'; END IF;
  IF p_status NOT IN ('new', 'reviewing', 'actioned', 'dismissed') THEN RAISE EXCEPTION 'unknown status' USING ERRCODE = '22023'; END IF;
  IF p_status = 'dismissed' AND (p_reason IS NULL OR p_reason NOT IN ('not_similar', 'different_goods', 'same_owner', 'coexistence', 'other')) THEN
    RAISE EXCEPTION 'a reason is required to dismiss' USING ERRCODE = '22023';
  END IF;
  IF p_status IN ('reviewing', 'actioned') AND a.opposition_deadline IS NULL AND p_deadline IS NULL THEN
    RAISE EXCEPTION 'enter the opposition deadline first' USING ERRCODE = '22004';
  END IF;
  UPDATE watch.alert SET status = p_status::watch.alert_status, dismiss_reason = CASE WHEN p_status = 'dismissed' THEN p_reason END,
         opposition_deadline = COALESCE(a.opposition_deadline, p_deadline),
         deadline_entered_by = CASE WHEN a.opposition_deadline IS NULL AND p_deadline IS NOT NULL THEN platform.current_user_id() ELSE a.deadline_entered_by END,
         status_by = platform.current_user_id(), updated_at = now()
   WHERE id = a.id;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_alert_set(uuid, text, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION watch.fn_alert_set(uuid, text, text, date) TO meesam_app;
-- alerts are changed only through the function above
DROP POLICY alert_update ON watch.alert;
REVOKE UPDATE, INSERT ON watch.alert FROM meesam_app;

-- E-mails about alerts (PRD Section 8.2: at creation, then a reminder and a final one while the alert is still new).
-- One row per active user of the account: new alerts not yet mailed, and alerts still "new" whose deadline is near.
-- The reminder days come from the registry profile (watch_alert_reminders_days), else from the engine settings.
CREATE FUNCTION watch.fn_alert_mails_take()
RETURNS TABLE (email text, name text, locale text, account_id uuid, kind text, alerts integer, high integer, nearest_deadline date, days_left integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, platform, public, pg_temp AS $$
BEGIN
  RETURN QUERY
  WITH fresh AS (
    UPDATE watch.alert a SET mailed_at = now() WHERE a.mailed_at IS NULL RETURNING a.account_id, a.risk_band, a.opposition_deadline
  ), grouped AS (
    SELECT f.account_id, count(*)::int AS n, (count(*) FILTER (WHERE f.risk_band = 'high'))::int AS high, min(f.opposition_deadline) AS nearest FROM fresh f GROUP BY f.account_id
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
    -- the next step not yet sent, once its day has come
    SELECT s.id, s.account_id, s.risk_band, s.opposition_deadline FROM steps s
     WHERE s.sent < jsonb_array_length(COALESCE(s.days, '[]'::jsonb)) AND (s.opposition_deadline - current_date) <= (s.days ->> s.sent)::int
  ), marked AS (
    UPDATE watch.alert a SET reminded_at = a.reminded_at || now() FROM due d WHERE d.id = a.id RETURNING d.account_id, d.risk_band, d.opposition_deadline
  ), grouped AS (
    SELECT m.account_id, count(*)::int AS n, (count(*) FILTER (WHERE m.risk_band = 'high'))::int AS high, min(m.opposition_deadline) AS nearest FROM marked m GROUP BY m.account_id
  )
  SELECT u.email::text, u.name, u.locale::text, g.account_id, 'reminder'::text, g.n, g.high, g.nearest, (g.nearest - current_date)::int
    FROM grouped g JOIN core.app_user u ON u.account_id = g.account_id AND u.status = 'active';
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_alert_mails_take() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_alert_mails_take() TO meesam_worker;

COMMIT;
