-- 0060 — Re-use register per registry (Founder ruling R8, 21 Nov 2026; Data Management and Use 10.4, Section 8.1).
-- One row per registry: the re-use terms as read, the date they were read, a link, and what they allow
-- (store, show, derive, train, contact). NULL in a "may" column means "not yet read", never "allowed".
-- The fetcher's re-use gate reads it: where the register says storing is not allowed, no publication of that
-- registry can be stored (fetched or added by hand), its sources are paused, and they cannot be switched on.
-- Confirming re-use for a source (0043) now also writes the register, so the two cannot disagree.
BEGIN;

CREATE TABLE watch.reuse_register (
  registry_id uuid PRIMARY KEY REFERENCES registry.registry(id),
  terms       text NULL,               -- the basis in words, as read
  terms_url   text NULL,
  read_on     date NULL,
  may_store   boolean NULL,
  may_show    boolean NULL,
  may_derive  boolean NULL,
  may_train   boolean NULL,
  may_contact boolean NULL,
  note        text NULL,
  updated_by  uuid NULL REFERENCES core.app_user(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.reuse_register
  FOR EACH ROW WHEN (platform.current_user_id() IS NOT NULL) EXECUTE FUNCTION platform.trg_audit_row();
GRANT SELECT ON watch.reuse_register TO meesam_staff, meesam_worker, meesam_admin;

-- What is already on record: every registry whose source was switched on carries a stated basis.
INSERT INTO watch.reuse_register (registry_id, terms, read_on, may_store)
SELECT DISTINCT ON (s.registry_id) s.registry_id, s.fetch_spec ->> 'reuse',
       NULLIF(s.fetch_spec ->> 'reuse_confirmed_on', '')::date, CASE WHEN s.active THEN true END
  FROM watch.publication_source s
 WHERE NULLIF(s.fetch_spec ->> 'reuse', '') IS NOT NULL
 ORDER BY s.registry_id, s.active DESC, (s.fetch_spec ->> 'reuse_confirmed_on') DESC NULLS LAST;

-- The watch operations lead keeps the register.
CREATE FUNCTION watch.fn_reuse_set(p_registry_id uuid, p_terms text, p_terms_url text, p_read_on date,
                                   p_store boolean, p_show boolean, p_derive boolean, p_train boolean, p_contact boolean,
                                   p_note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, registry, public, pg_temp AS $$
DECLARE v_url text := NULLIF(btrim(left(p_terms_url, 500)), '');
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN RAISE EXCEPTION 'the link must be a web address' USING ERRCODE = '22023'; END IF;
  IF p_read_on > current_date THEN RAISE EXCEPTION 'the date read cannot be in the future' USING ERRCODE = '22008'; END IF;
  INSERT INTO watch.reuse_register (registry_id, terms, terms_url, read_on, may_store, may_show, may_derive, may_train, may_contact, note, updated_by)
  VALUES (p_registry_id, NULLIF(btrim(left(p_terms, 1000)), ''), v_url, p_read_on, p_store, p_show, p_derive, p_train, p_contact,
          NULLIF(btrim(left(p_note, 500)), ''), platform.current_user_id())
  ON CONFLICT (registry_id) DO UPDATE
    SET terms = EXCLUDED.terms, terms_url = EXCLUDED.terms_url, read_on = EXCLUDED.read_on, may_store = EXCLUDED.may_store,
        may_show = EXCLUDED.may_show, may_derive = EXCLUDED.may_derive, may_train = EXCLUDED.may_train, may_contact = EXCLUDED.may_contact,
        note = EXCLUDED.note, updated_by = EXCLUDED.updated_by, updated_at = now();
  -- the gate: storing not allowed → nothing more is collected from this registry
  IF p_store IS FALSE THEN
    UPDATE watch.publication_source
       SET paused = true, paused_at = now(), paused_by = platform.current_user_id(),
           pause_note = 'The re-use register does not allow storing this registry''s publications', updated_at = now()
     WHERE registry_id = p_registry_id AND active AND NOT paused;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION watch.fn_reuse_set(uuid, text, text, date, boolean, boolean, boolean, boolean, boolean, text) FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION watch.fn_reuse_set(uuid, text, text, date, boolean, boolean, boolean, boolean, boolean, text) TO meesam_staff, meesam_admin;

-- The gate at the source: it cannot be switched on or resumed against the register.
CREATE FUNCTION watch.trg_source_reuse_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.active AND NOT NEW.paused AND (NOT OLD.active OR OLD.paused)
     AND EXISTS (SELECT 1 FROM watch.reuse_register r WHERE r.registry_id = NEW.registry_id AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow storing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER source_reuse_gate BEFORE UPDATE ON watch.publication_source FOR EACH ROW EXECUTE FUNCTION watch.trg_source_reuse_gate();

-- The gate at the file: nothing is recorded as stored against the register, fetched or added by hand.
CREATE FUNCTION watch.trg_issue_reuse_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.object_key IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.object_key IS DISTINCT FROM NEW.object_key)
     AND EXISTS (SELECT 1 FROM watch.reuse_register r JOIN watch.publication_source s ON s.registry_id = r.registry_id
                  WHERE s.id = NEW.source_id AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow storing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER issue_reuse_gate BEFORE INSERT OR UPDATE ON watch.publication_issue FOR EACH ROW EXECUTE FUNCTION watch.trg_issue_reuse_gate();

-- Confirming re-use for a source writes the register too (same checks and effect as 0043 otherwise).
CREATE OR REPLACE FUNCTION watch.fn_source_confirm_reuse(p_source_id uuid, p_basis text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = watch, platform, core, public, pg_temp AS $$
DECLARE v_basis text := NULLIF(btrim(left(p_basis, 300)), ''); v_registry uuid;
BEGIN
  IF NOT watch.fn_is_watch_lead() THEN RAISE EXCEPTION 'not allowed' USING ERRCODE = '42501'; END IF;
  IF v_basis IS NULL THEN RAISE EXCEPTION 'the basis of the confirmation is required' USING ERRCODE = '22023'; END IF;
  SELECT registry_id INTO v_registry FROM watch.publication_source WHERE id = p_source_id AND NOT active AND fetch_spec ? 'url';
  IF v_registry IS NULL THEN RAISE EXCEPTION 'no such source that is off and has a location' USING ERRCODE = 'P0002'; END IF;
  IF EXISTS (SELECT 1 FROM watch.reuse_register r WHERE r.registry_id = v_registry AND r.may_store IS FALSE) THEN
    RAISE EXCEPTION 'the re-use register does not allow storing this registry''s publications' USING ERRCODE = '42501';
  END IF;
  INSERT INTO watch.reuse_register (registry_id, terms, read_on, may_store, updated_by)
  VALUES (v_registry, v_basis, current_date, true, platform.current_user_id())
  ON CONFLICT (registry_id) DO UPDATE
    SET terms = COALESCE(watch.reuse_register.terms, EXCLUDED.terms), read_on = COALESCE(watch.reuse_register.read_on, EXCLUDED.read_on),
        may_store = true, updated_by = EXCLUDED.updated_by, updated_at = now();
  UPDATE watch.publication_source
     SET active = true, paused = false, failures = 0, next_poll_at = now(), updated_at = now(),
         fetch_spec = fetch_spec || jsonb_build_object('reuse', v_basis, 'reuse_confirmed_on', current_date,
                        'reuse_confirmed_by', (SELECT u.name FROM core.app_user u WHERE u.id = platform.current_user_id()))
   WHERE id = p_source_id;
END $$;

COMMIT;
