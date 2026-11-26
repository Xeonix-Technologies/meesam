-- Tests for migration 0097: the kind of a published mark, by the source's rules.
BEGIN;
SET client_min_messages = warning;
DO $$ DECLARE r jsonb := (SELECT s.fetch_spec #> '{read,kind}' FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code = 'AE' AND s.stream = 'national_bulletin'); BEGIN
  ASSERT r IS NOT NULL, 'the UAE source carries its lists';
  ASSERT watch.fn_mark_kind_of('كلمة بأحرف لاتينية SYLI بخط مميز باللون الأسود', 'SYLI', r) = 'word', 'lettering in a distinctive hand is still a word mark';
  ASSERT watch.fn_mark_kind_of('العلامة عبارة عن الكلمة hotbanana بأحرف لاتينية مميزة باللون الأسود كما هو موضح بالشكل', 'hotbanana', r) = 'word', '"as shown in the figure" is not a drawing';
  ASSERT watch.fn_mark_kind_of('رسم لشكل وجه مميز.', 'رسم', r) = 'device', 'a drawing whose wording only says "drawing"';
  ASSERT watch.fn_mark_kind_of('الرمز عبارة عن شكل بيضاوي بخلفية خضراء، يحتوي على نصف دائرة', 'شكل', r) = 'device', '"consists of" is not lettering';
  ASSERT watch.fn_mark_kind_of('العبارة KOOL كتبت بأحرف لاتينية يعلوها رسم لأداة موسيقية بشكل مميز.', 'KOOL', r) = 'word_device', 'words with a drawing above them';
  ASSERT watch.fn_mark_kind_of('HC أحرف لاتينية كتبت داخل رسم هندسي سداسي بشكل مميز.', 'HC', r) = 'device_word', 'letters inside a drawing';
  ASSERT watch.fn_mark_kind_of('The mark consists of a circular emblem bearing the word ALQARYON', 'ALQARYON', r) = 'word_device', 'English descriptions are read too';
  ASSERT watch.fn_mark_kind_of(NULL, 'RM HUB', r) IS NULL, 'no description: the wording alone does not say';
  ASSERT watch.fn_mark_kind_of(NULL, 'لا يوجد', r) = 'device', 'a wording that says there is none';
  ASSERT watch.fn_mark_kind_of('كلمة', 'X', NULL) IS NULL, 'a source without lists gives no kind';
  ASSERT (SELECT count(*) FROM core.mark_kind) = 4 AND (SELECT count(*) FROM core.mark_kind WHERE standard = 'combined') = 2, 'four kinds, two of them the standard''s "combined"';
END $$;
CREATE TEMP TABLE _t AS
  WITH s AS (SELECT s.id, s.registry_id, g.code FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE g.code IN ('AE', 'GB') AND s.stream = 'national_bulletin'),
       i AS (INSERT INTO watch.publication_issue (source_id, issue_no, published_on, object_key, container) SELECT id, 'T97', current_date - 20, code || '/national_bulletin/T97_x.pdf', 'pdf' FROM s RETURNING id, source_id)
  SELECT i.id AS issue_id, s.registry_id, s.code FROM i JOIN s ON s.id = i.source_id;
INSERT INTO watch.published_mark (issue_id, registry_id, publication_date, application_no, classes, mark_text, extraction)
SELECT issue_id, registry_id, current_date - 20, '970001', '{9}', '{"en": "HC"}', '{"other": {"description": "HC أحرف لاتينية كتبت داخل رسم هندسي"}}' FROM _t;
DO $$ DECLARE ae uuid := (SELECT issue_id FROM _t WHERE code = 'AE'); gb uuid := (SELECT issue_id FROM _t WHERE code = 'GB'); BEGIN
  ASSERT (SELECT mark_kind = 'device_word' AND mark_kind_by = 'rules' FROM watch.published_mark WHERE issue_id = ae), 'a mark read from the UAE gets its kind as it is stored';
  ASSERT (SELECT mark_kind IS NULL AND mark_kind_by IS NULL FROM watch.published_mark WHERE issue_id = gb), 'a source without lists leaves the kind empty';
  UPDATE watch.published_mark SET extraction = '{"other": {"description": "كلمة HC بأحرف لاتينية"}}' WHERE issue_id = ae;
  ASSERT (SELECT mark_kind = 'word' FROM watch.published_mark WHERE issue_id = ae), 'a new reading gives a new kind';
  UPDATE watch.published_mark SET mark_kind = 'device', mark_kind_by = 'person' WHERE issue_id = ae;
  UPDATE watch.published_mark SET extraction = '{"other": {"description": "HC أحرف لاتينية كتبت داخل رسم هندسي"}}' WHERE issue_id = ae;
  ASSERT (SELECT mark_kind = 'device' AND mark_kind_by = 'person' FROM watch.published_mark WHERE issue_id = ae), 'a kind set by a person is not overwritten by the rules';
END $$;
ROLLBACK;
\echo ALL 0097 TESTS PASSED
