-- 0097 — The kind of a mark (Founder ruling 26 Nov 2026).
--
-- The Founder's four kinds are kept and linked to the standard kind of mark (the three values Meesam already
-- holds for customers' marks, core.mark_type, which follow WIPO ST.96: word, figurative, combined):
--   word (word mark) · device (picture mark or device) · word_device (word mark with a device) ·
--   device_word (picture with wording inside or linked to it); the last two are both "combined".
-- For a published mark the kind is worked out by rules from what the registry itself prints: its wording and its
-- description of the mark. The word lists are data on the source (fetch_spec.read.kind), never literals in code;
-- a source without them gets no kind. A kind set by a person is never overwritten by the rules.
-- First source: the UAE bulletin, whose form carries "وصف العلامة" (description of the mark) on nearly every entry.
-- The rules are a first attempt, to be judged on the Pictures page before anything depends on them.
BEGIN;

CREATE TABLE core.mark_kind (
  code     text PRIMARY KEY,
  standard core.mark_type NOT NULL,
  label    jsonb NOT NULL,
  sort     smallint NOT NULL
);
INSERT INTO core.mark_kind (code, standard, label, sort) VALUES
  ('word',        'word',     '{"en": "Word mark", "ar": "علامة كلمة"}', 1),
  ('device',      'device',   '{"en": "Picture mark or device", "ar": "علامة صورة أو رسم"}', 2),
  ('word_device', 'combined', '{"en": "Word mark with a device", "ar": "علامة كلمة معها رسم"}', 3),
  ('device_word', 'combined', '{"en": "Picture with wording inside or linked to it", "ar": "صورة بداخلها كتابة أو مرتبطة بها"}', 4);
GRANT SELECT ON core.mark_kind TO meesam_app, meesam_worker, meesam_staff, meesam_admin, meesam_readonly;

ALTER TABLE watch.published_mark
  ADD COLUMN mark_kind    text NULL REFERENCES core.mark_kind(code),
  ADD COLUMN mark_kind_by text NULL CHECK (mark_kind_by IN ('rules', 'person'));

-- Text made comparable: lower case, the forms of alef, ya and ta marbuta brought together, vowel marks and
-- stretching removed, spaces collapsed.
CREATE FUNCTION watch.fn_kind_text(p text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT btrim(regexp_replace(regexp_replace(translate(lower(COALESCE(p, '')), 'أإآىة', 'ااايه'), E'[ً-ْـ]', '', 'g'), '\s+', ' ', 'g'))
$$;

-- The kind of a mark from its wording and the registry's description, by the source's rules:
--   no_wording: a wording that only says there is none ("رسم", "لا يوجد", "Device");
--   word / device: terms in the description that tell of lettering / of a drawing;
--   inside: terms that tell the lettering sits inside the drawing.
-- No description: no kind (the wording alone does not say whether a drawing comes with it).
CREATE FUNCTION watch.fn_mark_kind_of(p_description text, p_wording text, p_rules jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE t text := watch.fn_kind_text(p_description); w text := watch.fn_kind_text(p_wording);
        has_wording boolean; dev boolean; wrd boolean;
BEGIN
  IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'object' THEN RETURN NULL; END IF;
  has_wording := w <> '' AND NOT (p_rules ? 'no_wording' AND w ~ (p_rules ->> 'no_wording'));
  IF t = '' THEN
    RETURN CASE WHEN w <> '' AND NOT has_wording THEN 'device' END;
  END IF;
  dev := p_rules ? 'device' AND t ~ (p_rules ->> 'device');
  wrd := has_wording OR (p_rules ? 'word' AND t ~ (p_rules ->> 'word'));
  RETURN CASE WHEN dev AND wrd THEN CASE WHEN p_rules ? 'inside' AND t ~ (p_rules ->> 'inside') THEN 'device_word' ELSE 'word_device' END
              WHEN dev THEN 'device' WHEN wrd THEN 'word' END;
END $$;

CREATE FUNCTION watch.trg_mark_kind() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, public, pg_temp AS $$
DECLARE v_rules jsonb; v_kind text;
BEGIN
  IF NEW.mark_kind_by = 'person' THEN RETURN NEW; END IF;
  SELECT s.fetch_spec #> '{read,kind}' INTO v_rules
    FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id WHERE i.id = NEW.issue_id;
  IF v_rules IS NULL THEN RETURN NEW; END IF;
  v_kind := watch.fn_mark_kind_of(NEW.extraction #>> '{other,description}', concat_ws(' ', NEW.mark_text ->> 'ar', NEW.mark_text ->> 'en'), v_rules);
  NEW.mark_kind := v_kind;
  NEW.mark_kind_by := CASE WHEN v_kind IS NOT NULL THEN 'rules' END;
  RETURN NEW;
END $$;
CREATE TRIGGER mark_kind BEFORE INSERT OR UPDATE OF extraction, mark_text ON watch.published_mark
  FOR EACH ROW EXECUTE FUNCTION watch.trg_mark_kind();

-- The UAE's lists (26 Nov 2026, from the descriptions of bulletin 353). Patterns are applied to the text made
-- comparable by fn_kind_text, so they are written without hamza forms, with ه for ة and ي for ى.
UPDATE watch.publication_source ps
   SET fetch_spec = jsonb_set(ps.fetch_spec, '{read,kind}', jsonb_build_object(
         'device', 'رسم|رسوم|دائر|مربع|مستطيل|بيضاوي|مثلث|معين|سداسي|اطار|زخرف|رمز|نجم|هندسي|صوره|هلال|تاج|ورقه |قلب|سهم|قوس|مقوس|شريط|خلفيه (?!بيضاء|باللون الابيض|ابيض)|شكل (?!مميز|خاص|مبتكر|فني|المرفق|الموضح|المبين)|device|logo|emblem|figure|symbol|circle|square|shape|icon',
         'word', 'كلم|عباره(?! عن)|حرف|احرف|حروف|مكتوب|كتب|لفظ|اسم|رقم|ارقام|word|letter|text|written',
         'inside', 'داخل|ضمن|بداخل|يحتوي علي|تحتوي علي|inside|within',
         'no_wording', '^(رسم|شكل|لا يوجد|شعار|صوره|رمز|علامه|device|logo|-|\.)?( .{0,12})?$'), true),
       updated_at = now()
  FROM registry.registry g
 WHERE g.id = ps.registry_id AND g.code = 'AE' AND ps.stream = 'national_bulletin' AND ps.fetch_spec ? 'read';

-- The marks already read from the UAE get their kind now.
UPDATE watch.published_mark m
   SET mark_kind = k.kind, mark_kind_by = CASE WHEN k.kind IS NOT NULL THEN 'rules' END
  FROM (SELECT x.registry_id, x.publication_date, x.id,
               watch.fn_mark_kind_of(x.extraction #>> '{other,description}', concat_ws(' ', x.mark_text ->> 'ar', x.mark_text ->> 'en'), s.fetch_spec #> '{read,kind}') AS kind
          FROM watch.published_mark x JOIN watch.publication_issue i ON i.id = x.issue_id JOIN watch.publication_source s ON s.id = i.source_id
         WHERE s.fetch_spec #> '{read,kind}' IS NOT NULL AND x.mark_kind_by IS DISTINCT FROM 'person') k
 WHERE m.registry_id = k.registry_id AND m.publication_date = k.publication_date AND m.id = k.id;

COMMIT;
