-- 0061 — A record is matched to its published mark, never merged (Founder ruling R5, 21 Nov 2026;
-- Data Management and Use 10.1, 10.2, Section 5.3; CLAUDE.md rule 13).
-- What a registry publishes stays in watch.published_mark; what an account enters stays in core.record.
-- The two meet only here, as a link: by registry and application number. The link never writes to the record.
-- Where the two disagree, the account is shown an advisory "Registry shows…" note (rule 6: warn, never block).
-- Only marks that have passed verification are matched, so nothing unverified reaches a user.
-- The note is shown only where the re-use register (0060) says the registry's data may be shown.
-- Not built here: a match without a number (a scored match the user confirms) belongs to the comparison stage.
BEGIN;

-- A number as typed, reduced to what identifies it: letters and digits only, upper case ("407-950 " = "407950").
CREATE FUNCTION core.fn_number_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(upper(regexp_replace(COALESCE(p, ''), '[^[:alnum:]]', '', 'g')), '')
$$;
CREATE INDEX record_application_key ON core.record (registry_id, core.fn_number_key(application_no)) WHERE application_no IS NOT NULL;
CREATE INDEX published_mark_application_key ON watch.published_mark (core.fn_number_key(application_no)) WHERE application_no IS NOT NULL;

CREATE TABLE watch.record_match (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id        uuid NOT NULL REFERENCES core.record(id) ON DELETE CASCADE,
  registry_id      uuid NOT NULL,
  publication_date date NOT NULL,
  mark_id          uuid NOT NULL,
  matched_by       text NOT NULL CHECK (matched_by IN ('number', 'confirmed')),
  differences      jsonb NOT NULL DEFAULT '[]'::jsonb,     -- [{field, record, registry}] as they stood when matched
  matched_at       timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (registry_id, publication_date, mark_id) REFERENCES watch.published_mark (registry_id, publication_date, id),
  UNIQUE (record_id, mark_id)
);
CREATE INDEX ON watch.record_match (record_id, publication_date DESC);
CREATE INDEX ON watch.record_match (registry_id, publication_date, mark_id);
ALTER TABLE watch.record_match ENABLE ROW LEVEL SECURITY;          -- no policy for the app role: it reads through core.fn_registry_shows
GRANT SELECT ON watch.record_match TO meesam_staff, meesam_worker, meesam_admin;
CREATE POLICY record_match_staff ON watch.record_match FOR SELECT TO meesam_staff, meesam_worker, meesam_admin USING (true);

-- Where the record and the published mark disagree, field by field. Names of owners vary too much in spelling to
-- be compared safely, so they are shown, not compared.
CREATE FUNCTION watch.fn_match_differences(p_record_id uuid, p_registry_id uuid, p_publication_date date, p_mark_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = watch, core, registry, public, pg_temp AS $$
DECLARE r core.record; m watch.published_mark; d jsonb := '[]'::jsonb; k text; rc smallint[]; a text; b text;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id;
  SELECT * INTO m FROM watch.published_mark WHERE registry_id = p_registry_id AND publication_date = p_publication_date AND id = p_mark_id;
  IF r.id IS NULL OR m.id IS NULL THEN RETURN d; END IF;
  FOR k IN SELECT jsonb_object_keys(COALESCE(r.mark_text, '{}'::jsonb)) INTERSECT SELECT jsonb_object_keys(COALESCE(m.mark_text, '{}'::jsonb)) LOOP
    a := lower(btrim(regexp_replace(r.mark_text ->> k, '\s+', ' ', 'g')));
    b := lower(btrim(regexp_replace(m.mark_text ->> k, '\s+', ' ', 'g')));
    IF a <> '' AND b <> '' AND a <> b THEN
      d := d || jsonb_build_object('field', 'mark_text', 'lang', k, 'record', r.mark_text ->> k, 'registry', m.mark_text ->> k);
    END IF;
  END LOOP;
  SELECT COALESCE(array_agg(n.number ORDER BY n.number), '{}') INTO rc FROM core.record_class c JOIN registry.nice_class n ON n.id = c.nice_class_id WHERE c.record_id = r.id;
  IF cardinality(rc) > 0 AND cardinality(m.classes) > 0 AND rc <> (SELECT array_agg(x ORDER BY x) FROM unnest(m.classes) x) THEN
    d := d || jsonb_build_object('field', 'classes', 'record', to_jsonb(rc), 'registry', (SELECT to_jsonb(array_agg(x ORDER BY x)) FROM unnest(m.classes) x));
  END IF;
  RETURN d;
END $$;

-- One published mark against the records of its registry (called when the mark passes verification).
CREATE FUNCTION watch.fn_match_mark(p_registry_id uuid, p_publication_date date, p_mark_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, public, pg_temp AS $$
DECLARE m watch.published_mark; n integer;
BEGIN
  SELECT * INTO m FROM watch.published_mark WHERE registry_id = p_registry_id AND publication_date = p_publication_date AND id = p_mark_id;
  IF m.id IS NULL OR m.verify_state = 'ai_extracted' OR core.fn_number_key(m.application_no) IS NULL THEN RETURN 0; END IF;
  INSERT INTO watch.record_match (record_id, registry_id, publication_date, mark_id, matched_by, differences)
  SELECT r.id, m.registry_id, m.publication_date, m.id, 'number', watch.fn_match_differences(r.id, m.registry_id, m.publication_date, m.id)
    FROM core.record r
   WHERE r.registry_id = m.registry_id AND r.application_no IS NOT NULL AND core.fn_number_key(r.application_no) = core.fn_number_key(m.application_no)
  ON CONFLICT (record_id, mark_id) DO UPDATE SET differences = EXCLUDED.differences, updated_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- One record against the marks already published by its registry (called when a record gets or changes its number).
CREATE FUNCTION watch.fn_match_record(p_record_id uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, public, pg_temp AS $$
DECLARE r core.record; n integer;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id;
  -- a number that changed no longer points at the marks matched by the old one
  DELETE FROM watch.record_match x USING watch.published_mark m
   WHERE x.record_id = p_record_id AND x.matched_by = 'number'
     AND m.registry_id = x.registry_id AND m.publication_date = x.publication_date AND m.id = x.mark_id
     AND core.fn_number_key(m.application_no) IS DISTINCT FROM core.fn_number_key(r.application_no);
  IF r.id IS NULL OR core.fn_number_key(r.application_no) IS NULL THEN RETURN 0; END IF;
  INSERT INTO watch.record_match (record_id, registry_id, publication_date, mark_id, matched_by, differences)
  SELECT r.id, m.registry_id, m.publication_date, m.id, 'number', watch.fn_match_differences(r.id, m.registry_id, m.publication_date, m.id)
    FROM watch.published_mark m
   WHERE m.registry_id = r.registry_id AND m.verify_state <> 'ai_extracted' AND m.application_no IS NOT NULL
     AND core.fn_number_key(m.application_no) = core.fn_number_key(r.application_no)
  ON CONFLICT (record_id, mark_id) DO UPDATE SET differences = EXCLUDED.differences, updated_at = now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_match_mark(uuid, date, uuid), watch.fn_match_record(uuid), watch.fn_match_differences(uuid, uuid, date, uuid) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_match_mark(uuid, date, uuid), watch.fn_match_record(uuid), watch.fn_match_differences(uuid, uuid, date, uuid) TO meesam_worker, meesam_staff, meesam_admin;

CREATE FUNCTION watch.trg_mark_match() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, public, pg_temp AS $$
BEGIN
  IF NEW.verify_state <> 'ai_extracted' THEN PERFORM watch.fn_match_mark(NEW.registry_id, NEW.publication_date, NEW.id); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER mark_match AFTER INSERT OR UPDATE OF verify_state, application_no, mark_text, classes ON watch.published_mark
  FOR EACH ROW EXECUTE FUNCTION watch.trg_mark_match();

CREATE FUNCTION core.trg_record_match() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, core, registry, public, pg_temp AS $$
BEGIN
  PERFORM watch.fn_match_record(NEW.id);
  RETURN NULL;
END $$;
CREATE TRIGGER record_match AFTER INSERT OR UPDATE OF application_no, registry_id ON core.record
  FOR EACH ROW EXECUTE FUNCTION core.trg_record_match();

-- What the account sees: the latest publication matched to a record it may access, with the registry's own values
-- and the differences. Empty unless the re-use register allows showing that registry's data.
CREATE FUNCTION core.fn_registry_shows(p_record_id uuid)
RETURNS TABLE (publication_date date, issue_no text, application_no text, mark_text jsonb, classes smallint[], applicant_name text,
               agent_name text, page integer, differences jsonb, matched_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = watch, core, registry, platform, public, pg_temp AS $$
  SELECT m.publication_date, i.issue_no, m.application_no, m.mark_text, m.classes, m.applicant_name, m.agent_name,
         NULLIF(m.extraction ->> 'page', '')::integer, watch.fn_match_differences(x.record_id, m.registry_id, m.publication_date, m.id), x.matched_at
    FROM watch.record_match x
    JOIN watch.published_mark m ON m.registry_id = x.registry_id AND m.publication_date = x.publication_date AND m.id = x.mark_id
    JOIN watch.publication_issue i ON i.id = m.issue_id
    JOIN watch.reuse_register u ON u.registry_id = m.registry_id AND u.may_show IS TRUE
   WHERE x.record_id = p_record_id
     AND core.fn_can_access(p_record_id, platform.current_account_id())
     AND m.verify_state <> 'ai_extracted'
   ORDER BY m.publication_date DESC, x.matched_at DESC
   LIMIT 1
$$;
REVOKE EXECUTE ON FUNCTION core.fn_registry_shows(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_registry_shows(uuid) TO meesam_app, meesam_staff, meesam_admin;

COMMIT;
