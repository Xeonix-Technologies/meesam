-- 0074 — The reviewer also corrects the goods or services and the applicant's address (Founder, 22 Nov 2026:
-- "Goods or services can not be corrected and the list shortened"). The AI reader now gives the goods in full
-- (worker), and fn_mark_verify takes "goods" and "applicant_address" like the other fields: what the reader gave is
-- kept beside the correction, and the corrected fields are named. Nothing else in the function changes.
BEGIN;

CREATE OR REPLACE FUNCTION watch.fn_mark_verify(p_issue_id uuid, p_mark_id uuid, p_fix jsonb DEFAULT '{}'::jsonb) RETURNS text[]
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
  -- the goods or services and the applicant's address, as printed (long texts; line breaks are kept)
  IF f ? 'goods' THEN v_extra := v_extra || jsonb_build_object('goods', NULLIF(regexp_replace(left(f ->> 'goods', 20000), clean, '', 'g'), '')); END IF;
  IF f ? 'applicant_address' THEN v_extra := v_extra || jsonb_build_object('applicant_address', NULLIF(regexp_replace(left(f ->> 'applicant_address', 1000), clean, '', 'g'), '')); END IF;

  IF n.application_no IS DISTINCT FROM m.application_no THEN v_changed := v_changed || 'application_no'::text; END IF;
  IF n.mark_text IS DISTINCT FROM m.mark_text THEN v_changed := v_changed || 'mark_text'::text; END IF;
  IF n.classes IS DISTINCT FROM m.classes THEN v_changed := v_changed || 'classes'::text; END IF;
  IF n.applicant_name IS DISTINCT FROM m.applicant_name THEN v_changed := v_changed || 'applicant_name'::text; END IF;
  IF n.applicant_country IS DISTINCT FROM m.applicant_country THEN v_changed := v_changed || 'applicant_country'::text; END IF;
  IF n.agent_name IS DISTINCT FROM m.agent_name THEN v_changed := v_changed || 'agent_name'::text; END IF;
  FOREACH k IN ARRAY ARRAY['filing_date', 'agent_city', 'goods', 'applicant_address'] LOOP
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
      'applicant_name', m.applicant_name, 'applicant_country', m.applicant_country, 'agent_name', m.agent_name, 'filing_date', m.extraction -> 'filing_date', 'agent_city', m.extraction -> 'agent_city',
      'goods', m.extraction -> 'goods', 'applicant_address', m.extraction -> 'applicant_address'));
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

COMMIT;
