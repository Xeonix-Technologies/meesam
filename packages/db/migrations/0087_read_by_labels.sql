-- 0087 — Reading a bulletin by its printed labels (the UAE first); the other parts of an issue are kept as notices.
--
-- Founder rulings 24 Nov 2026, after the examination of the UAE bulletin 353 (an archive of eleven files):
--   * The UAE bulletin is read by rules, without the AI reader. Its notices carry no printed codes; they are
--     printed on forms with fixed labels ("المودعة بالرقم :", "بإسم :", "Holder's Name:"), or as tables. The
--     title that tells which form a file holds, the labels, where a form's columns part and the columns of a
--     table are data on the source (fetch_spec.read.forms); the method is "labels".
--   * A person verifies every UAE mark to begin with ("Option C"): no "accept" setting is written for the UAE.
--     The setting "complete" is made ready here for the day it is ruled: a mark read by rules with nothing
--     missing is then accepted without a person. The UAE prints no list of the accepted numbers, so there is
--     nothing to compare with as there is for Türkiye ("complete_and_listed").
--   * All parts are read now ("Scope 2"). Accepted marks and Madrid designations are marks for the watch. The
--     other parts (change of the mark, of the goods, of the agent, of the owner's details; licence; transfer;
--     registrations; renewals) are news about marks already filed: they are stored with their source in
--     watch.published_notice and shown nowhere yet. They never touch a trademark record (rule 13).
--     RULING NEEDED: what Meesam does with these notices (who is told, how; whether a change of the mark or of
--     the goods raises a watch alert). The Data Architecture v0.2 foresees "registered, renewed, recordal" only
--     as a type in the prospect area, on a published mark; keeping them apart from published_mark is the
--     narrowest reading, so the watch never compares them.
--     RULING NEEDED: a Madrid notice prints only the international registration number. It is stored as
--     "IR <number>" (the prefix is a setting of the form), so it is never taken for a national application
--     number that happens to be the same; the number as printed is kept beside it (international_no).
--     Found: a Madrid notice prints no wording, only the picture of the mark, so these marks are stored but the
--     word comparison has nothing to compare until the picture is read or the wording comes from another source.
BEGIN;

-- 1. the notices of the parts that do not publish applications
CREATE TABLE watch.published_notice (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id         uuid NOT NULL REFERENCES watch.publication_issue(id),
  registry_id      uuid NOT NULL REFERENCES registry.registry(id),
  publication_date date NOT NULL,
  part             text NOT NULL CHECK (part ~ '^[a-z0-9_]{1,40}$'),     -- the form's name in the source's settings
  application_no   text NULL,
  fields           jsonb NOT NULL DEFAULT '{}'::jsonb,                    -- what the notice states, as printed
  source           jsonb NOT NULL DEFAULT '{}'::jsonb,                    -- file, page, page_to, run_id, read_by, complete
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX published_notice_issue ON watch.published_notice (issue_id, part);
CREATE INDEX published_notice_number ON watch.published_notice (registry_id, core.fn_number_key(application_no)) WHERE application_no IS NOT NULL;
ALTER TABLE watch.published_notice ENABLE ROW LEVEL SECURITY;
CREATE POLICY published_notice_read ON watch.published_notice FOR SELECT TO meesam_staff, meesam_admin, meesam_worker USING (true);
GRANT SELECT ON watch.published_notice TO meesam_staff, meesam_admin, meesam_worker;

-- the worker stores the notices of one part, some at a time; the first lot of a part replaces what an earlier reading stored
CREATE FUNCTION watch.fn_read_notices_store(p_run_id uuid, p_part text, p_rows jsonb, p_first boolean) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, registry, core, public, pg_temp AS $$
DECLARE r record; n integer;
BEGIN
  SELECT u.id, i.id AS issue_id, i.published_on, s.registry_id INTO r
    FROM watch.read_run u JOIN watch.publication_issue i ON i.id = u.issue_id JOIN watch.publication_source s ON s.id = i.source_id
   WHERE u.id = p_run_id AND u.model = 'rules';
  IF r.id IS NULL THEN RAISE EXCEPTION 'no such reading by rules' USING ERRCODE = 'P0002'; END IF;
  IF p_part IS NULL OR p_part !~ '^[a-z0-9_]{1,40}$' THEN RAISE EXCEPTION 'the part has no proper name' USING ERRCODE = '22023'; END IF;
  IF r.published_on IS NULL THEN RAISE EXCEPTION 'the issue has no publication date' USING ERRCODE = '22004'; END IF;
  IF EXISTS (SELECT 1 FROM watch.reuse_register g WHERE g.registry_id = r.registry_id AND g.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow storing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  IF p_first THEN DELETE FROM watch.published_notice WHERE issue_id = r.issue_id AND part = p_part; END IF;
  INSERT INTO watch.published_notice (issue_id, registry_id, publication_date, part, application_no, fields, source)
  SELECT r.issue_id, r.registry_id, r.published_on, p_part, NULLIF(btrim(left(x ->> 'application_no', 60)), ''),
         CASE WHEN jsonb_typeof(x -> 'fields') = 'object' THEN x -> 'fields' ELSE '{}'::jsonb END,
         jsonb_strip_nulls(jsonb_build_object('file', left(x ->> 'file', 300), 'page', x -> 'page', 'page_to', x -> 'page_to', 'complete', x -> 'complete', 'run_id', p_run_id, 'read_by', 'labels'))
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_rows) = 'array' THEN p_rows ELSE '[]'::jsonb END) x;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_read_notices_store(uuid, text, jsonb, boolean) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_read_notices_store(uuid, text, jsonb, boolean) TO meesam_worker;

-- 2. asking for a reading: a source read by labels is read by rules too (no model, no entry marker, no limit in pages or per day)
CREATE OR REPLACE FUNCTION watch.fn_read_run_request(p_issue_id uuid, p_model text, p_token_cap bigint DEFAULT 3000000, p_from_page integer DEFAULT NULL, p_to_page integer DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_id uuid; v_model text := NULLIF(btrim(left(p_model, 80)), ''); i record;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  SELECT x.id, x.published_on, s.registry_id, COALESCE(s.fetch_spec -> 'read' ->> 'entry_start', s.fetch_spec -> 'read' ->> 'entry_marker') AS marker,
         COALESCE(s.fetch_spec -> 'read' ->> 'method', '') IN ('codes', 'labels') AS by_codes INTO i
    FROM watch.publication_issue x JOIN watch.publication_source s ON s.id = x.source_id
   WHERE x.id = p_issue_id AND x.object_key IS NOT NULL;
  IF i.id IS NULL THEN RAISE EXCEPTION 'no such stored issue' USING ERRCODE = 'P0002'; END IF;
  -- a bulletin read by its printed codes or labels asks no AI reader: no model, no size ceiling to choose, no daily limit
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

-- 3. the marks of one reading by rules that need no person: by codes or by labels; "complete" asks for no list
CREATE OR REPLACE FUNCTION watch.fn_read_run_accept(p_run_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
DECLARE r record; n integer;
BEGIN
  SELECT u.id, u.issue_id, u.from_page, s.fetch_spec -> 'read' ->> 'accept' AS accept INTO r
    FROM watch.read_run u JOIN watch.publication_issue i ON i.id = u.issue_id JOIN watch.publication_source s ON s.id = i.source_id
   WHERE u.id = p_run_id AND u.model = 'rules';
  IF r.id IS NULL OR r.accept IS NULL OR r.accept NOT IN ('complete_and_listed', 'complete') THEN RETURN 0; END IF;
  PERFORM set_config('meesam.bulk_compare', 'on', true);
  WITH idx AS (
    SELECT DISTINCT core.fn_number_key(x ->> 'application_no') AS k
      FROM watch.read_part p, jsonb_array_elements(CASE WHEN jsonb_typeof(p.result -> 'rows') = 'array' THEN p.result -> 'rows' ELSE '[]'::jsonb END) x
     WHERE p.run_id = p_run_id AND p.kind = 'index' AND p.status = 'done'),
  done AS (
    UPDATE watch.published_mark m
       SET verify_state = 'waived', extraction = m.extraction || jsonb_build_object('accepted', 'rules', 'accepted_at', now()), updated_at = now()
     WHERE m.issue_id = r.issue_id AND m.verify_state = 'ai_extracted' AND m.extraction ->> 'run_id' = p_run_id::text AND m.extraction ->> 'read_by' IN ('codes', 'labels')
       AND m.extraction ->> 'confidence' = '1' AND m.application_no IS NOT NULL AND cardinality(m.classes) > 0
       -- "complete_and_listed", a whole issue: the number must be in the office's own list; some pages only, or "complete": completeness decides
       AND (r.accept = 'complete' OR r.from_page IS NOT NULL OR core.fn_number_key(m.application_no) IN (SELECT k FROM idx))
    RETURNING 1)
  SELECT count(*)::int INTO n FROM done;
  PERFORM set_config('meesam.bulk_compare', '', true);
  IF n > 0 THEN PERFORM platform.enqueue_job('watch.compare_issue', jsonb_build_object('issue_id', r.issue_id), now(), 'watch.compare_issue:' || r.issue_id); END IF;
  RETURN n;
END $$;

-- 4. the UAE bulletin is read by its printed labels. Every value here is the office's own wording or the place of
--    its text on the page (points from the left and from the top of a page), as data. No "accept": a person verifies.
UPDATE watch.publication_source s
   SET fetch_spec = jsonb_set(s.fetch_spec, '{read}', (COALESCE(s.fetch_spec -> 'read', '{}'::jsonb) - 'accept') || $ae$
  {
    "method": "labels",
    "prepare": "arabic_order",
    "observed": "24 Nov 2026, bulletin 353 of 3 Nov 2026: an archive of eleven files made with a word processor, the text inside; accepted marks and six kinds of change on one two-column form (right column first; under the picture the columns part elsewhere), Madrid on an English form with the international registration number and no wording, registrations and renewals as tables; no list of the accepted numbers is printed. Read by rules: 1,204 accepted marks, all complete, numbers all different; 265 Madrid; 526 changes; 978 registrations; 2,186 renewals.",
    "forms": [
      {"key": "accepted", "kind": "marks", "title": "^نموذجإعلانالنشر(?!عن)", "layout": "columns", "start": "نموذج إعلان النشر", "title_height": 20, "top": 60, "bottom": 705, "split": {"upper": 261, "lower": 301}, "break": "صورة العلامة", "skip": ["تعلن إدارة العلامات التجارية عن تقدم"], "labels": [{"label": "وكيل التسجيل / المالك :", "field": "agent"}, {"label": "طلب لتسجيل بيانات العلامة التجارية :", "field": "mark"}, {"label": "المودعة بالرقم", "field": "number"}, {"label": "بتاريخ", "field": "filed", "inline": "number"}, {"label": "بيانات الأولوية :", "field": "priority"}, {"label": "بإسم :", "field": "applicant"}, {"label": "وعنوانة :", "field": "address"}, {"label": "وذلك لتمييز السلع أو الخدمات الواقعة بالفئة :", "field": "classes"}, {"label": "وصف العلامة :", "field": "description"}, {"label": "الاشتراطات :", "field": "conditions"}], "then": {"classes": "goods"}, "end": "فعلي من لدية إعتراض"},
      {"key": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنالتعديل\\(شكلالعلامة\\)", "layout": "columns", "start": "نموذج إعلان النشر", "title_height": 20, "top": 60, "bottom": 705, "split": {"upper": 261, "lower": 301}, "break": "صورة العلامة", "skip": ["تعلن إدارة العلامات التجارية عن تقدم", "بيانات المالك بعد التعديل"], "labels": [{"label": "مقدم الطلب / وكيل التسجيل / مالك العلامة", "field": "agent"}, {"label": "وكيل التسجيل / مالك العلامة", "field": "agent"}, {"label": "وكيل التسجيل / المالك :", "field": "agent"}, {"label": "مقدم الطلب /", "field": "agent"}, {"label": "بطلب لتعديل بيانات العلامة التجارية :", "field": "mark"}, {"label": "طلب لتعديل بيانات العلامة التجارية :", "field": "mark"}, {"label": "بطلب تعديل بيانات العلامة التجارية :", "field": "mark"}, {"label": "بطلب انتقال ملكية العلامة التجارية :", "field": "mark"}, {"label": "بطلب ترخيص باستعمال العلامة التجارية :", "field": "mark"}, {"label": "المودعة بالرقم", "field": "number"}, {"label": "بتاريخ", "field": "filed", "inline": "number"}, {"label": "والمسجلة بتاريخ :", "field": "registered"}, {"label": "بإسم :", "field": "applicant"}, {"label": "وعنوانة :", "field": "address"}, {"label": "وذلك لتمييز السلع أو الخدمات الواقعة بالفئة :", "field": "classes"}, {"label": "بيانات التعديل:", "field": "change"}, {"label": "إسم المالك :", "field": "new_owner"}, {"label": "إسم من انتقلت الية الملكية:", "field": "new_owner"}, {"label": "إسم المرخص لة :", "field": "licensee"}, {"label": "عنوانة:", "field": "new_address"}, {"label": "تاريخ التعديل :", "field": "changed_on"}, {"label": "تاريخ انتقال الملكية :", "field": "changed_on"}, {"label": "تاريخ الترخيص:", "field": "changed_on"}, {"label": "تاريخ التأشير :", "field": "recorded_on"}], "then": {"classes": "goods"}, "end": "فعلي من لدية إعتراض"},
      {"key": "change_of_goods", "like": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنالتعديل\\(بيانالمنتجات\\)", "layout": "columns"},
      {"key": "change_of_agent", "like": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنالتعديل\\(تغييروكيلالتسجيل\\)", "layout": "columns"},
      {"key": "change_of_owner_details", "like": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنالتعديل\\(بياناتالمالك\\)", "layout": "columns"},
      {"key": "licence", "like": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنالترخيص", "layout": "columns"},
      {"key": "transfer", "like": "change_of_mark", "kind": "notices", "title": "^نموذجإعلانالنشرعنانتقالالملكية", "layout": "columns"},
      {"key": "madrid", "kind": "marks", "title": "^TheTrademarksDepartment", "layout": "plain", "start": "The Trademarks Department", "top": 60, "bottom": 735, "label_x_max": 150, "number_prefix": "IR ", "skip": ["announces the publication of", "Representation of the Mark", "International Trademark Registration"], "labels": [{"label": "No.:", "field": "number"}, {"label": "Date:", "field": "filed", "inline": "number"}, {"label": "Holder’s Name:", "field": "applicant"}, {"label": "Holder’s Address:", "field": "address"}, {"label": "Class(es) :", "field": "classes"}, {"label": "Goods and Services:", "field": "goods", "inline": "classes"}, {"label": "Trademark", "field": "description"}, {"label": "Description:", "field": "description"}, {"label": "Disclaimer:", "field": "conditions"}], "margin": {"field": "goods", "below_x": 150, "to": "classes"}, "end": "Anyone who wishes to object"},
      {"key": "registered", "kind": "notices", "title": "^النشرعنالعلاماتالمسجل", "layout": "table", "top": 80, "number_pattern": "\\d{4,8}", "columns": [{"field": "number", "to": 60}, {"field": "filed", "to": 150}, {"field": "registration_no", "to": 205}, {"field": "registered", "to": 266}, {"field": "mark", "to": 339}, {"field": "applicant", "to": 480}, {"field": "classes", "to": 521}, {"field": "status", "to": 9999}]},
      {"key": "renewed", "kind": "notices", "title": "^النشرعنتجديدالتسجيل", "layout": "table", "top": 80, "number_pattern": "\\d{4,8}", "columns": [{"field": "number", "to": 60}, {"field": "filed", "to": 150}, {"field": "registered", "to": 208}, {"field": "applicant", "to": 406}, {"field": "address", "to": 9999}]}
    ]
  }
  $ae$::jsonb)
  FROM registry.registry g
 WHERE g.id = s.registry_id AND g.code = 'AE' AND s.stream = 'national_bulletin';

COMMIT;
