-- 0113 — The record is filled from its certificate and confirmed with a tick; a correction is checked
-- (Founder, 28 Nov 2026: "what if all information added from Meesam reading the certificate and filling all
-- information, and the owner or the agency confirm it with a tick; if any mistake happened he writes it on the
-- side and Meesam validates it". Ruled the same day: a correction is checked against the certificate and against
-- what the registry published, both where available; a correction they do not bear out holds activation and
-- alerts Meesam's administrators and the person who entered it; a reading still never changes the number.)
--   * Fill: when the certificate in use is this record's (its number and office agree), a mark that is not active
--     takes the mark's wording and the classes from it (core.fn_certificate_apply); the dates already did (0109).
--   * Tick: the reading in use is confirmed by a user of the account (any role except Viewer). A registered mark
--     is ready for activation only when its certificate agrees, is confirmed, and no correction is open.
--   * Correction: the user states the right value of one field (wording, classes, a date). The application asks
--     the reader whether the certificate bears it out and reports the answer here; the database looks at what
--     the registry published for this record (0061), where that may be shown. Borne out by the certificate and
--     not contradicted by the publication: accepted, and the reading carries the corrected value from then on.
--     Otherwise held, until a System Administrator settles it or the account withdraws it.
-- The number and the issuing office are never corrected this way: they are what ties a certificate to a record.
BEGIN;

ALTER TABLE core.certificate_reading
  ADD COLUMN confirmed_at         timestamptz NULL,
  ADD COLUMN confirmed_by_user_id uuid NULL REFERENCES core.app_user(id);

-- a reading whose values change is no longer the one that was confirmed
CREATE FUNCTION core.trg_certificate_reading_unconfirm() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.expiry_date, NEW.filing_date, NEW.registration_date, NEW.application_no, NEW.registration_no, NEW.office_code, NEW.classes, NEW.mark_text_ar, NEW.mark_text_en, NEW.state)
     IS DISTINCT FROM (OLD.expiry_date, OLD.filing_date, OLD.registration_date, OLD.application_no, OLD.registration_no, OLD.office_code, OLD.classes, OLD.mark_text_ar, OLD.mark_text_en, OLD.state) THEN
    NEW.confirmed_at := NULL; NEW.confirmed_by_user_id := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER certificate_reading_unconfirm BEFORE UPDATE ON core.certificate_reading FOR EACH ROW EXECUTE FUNCTION core.trg_certificate_reading_unconfirm();

CREATE TABLE core.certificate_correction (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id           uuid NOT NULL REFERENCES core.record(id),
  document_id         uuid NOT NULL REFERENCES core.document(id),
  account_id          uuid NOT NULL REFERENCES core.account(id),
  user_id             uuid NOT NULL REFERENCES core.app_user(id),
  field               text NOT NULL CHECK (field IN ('mark_text_en', 'mark_text_ar', 'classes', 'filing_date', 'registration_date', 'expiry_date')),
  certificate_value   text NULL,                                  -- as Meesam read it
  corrected_value     text NOT NULL CHECK (btrim(corrected_value) <> '' AND length(corrected_value) <= 300),
  state               text NOT NULL DEFAULT 'checking' CHECK (state IN ('checking', 'accepted', 'held', 'rejected', 'withdrawn')),
  certificate_check   text NULL CHECK (certificate_check IN ('supports', 'contradicts', 'unclear')),
  certificate_passage text NULL,
  published_check     text NULL CHECK (published_check IN ('supports', 'contradicts', 'none')),
  published_value     text NULL,
  model               text NULL,
  input_tokens        integer NULL,
  output_tokens       integer NULL,
  settled_by_user_id  uuid NULL REFERENCES core.app_user(id),
  settled_note        text NULL,
  settled_at          timestamptz NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX certificate_correction_one_open ON core.certificate_correction (record_id, field) WHERE state IN ('checking', 'held');
CREATE INDEX ON core.certificate_correction (state, created_at) WHERE state = 'held';
ALTER TABLE core.certificate_correction ENABLE ROW LEVEL SECURITY;
CREATE POLICY certificate_correction_select ON core.certificate_correction FOR SELECT TO meesam_app
  USING (core.fn_can_access(record_id, platform.current_account_id()));
GRANT SELECT ON core.certificate_correction TO meesam_app, meesam_admin, meesam_readonly;
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON core.certificate_correction FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row();

-- The reading in use for a record: the one fn_activation_needs goes by.
CREATE FUNCTION core.fn_certificate_in_use(p_record_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT c.document_id FROM core.certificate_reading c JOIN core.document d ON d.id = c.document_id
   WHERE d.record_id = p_record_id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN') AND c.state = 'read' AND core.fn_i_hold_record(p_record_id)
   ORDER BY c.expiry_date DESC, c.read_at DESC LIMIT 1
$$;

-- As 0112, with the tick and the open corrections.
DROP FUNCTION core.fn_activation_needs(uuid);
CREATE FUNCTION core.fn_activation_needs(p_record_id uuid, OUT has_image boolean, OUT needs_certificate boolean, OUT has_certificate boolean,
                                         OUT certificate_state text, OUT certificate_expiry date, OUT record_expiry date,
                                         OUT certificate_filing date, OUT record_filing date, OUT expiry_agrees boolean, OUT filing_agrees boolean,
                                         OUT certificate_number text, OUT number_agrees boolean,
                                         OUT certificate_office text, OUT record_office text, OUT office_agrees boolean,
                                         OUT certificate_classes smallint[], OUT record_classes smallint[], OUT classes_agree boolean,
                                         OUT certificate_name text, OUT name_agrees boolean, OUT number_taken boolean,
                                         OUT certificate_confirmed boolean, OUT corrections_open integer, OUT ready boolean)
LANGUAGE sql STABLE AS $$
  SELECT z.has_image, z.registered, z.has_certificate,
         CASE WHEN NOT z.registered THEN NULL ELSE z.cert_state END,
         z.cert_expiry, z.record_expiry, z.cert_filing, z.record_filing, z.expiry_ok, z.filing_ok, z.cert_number, z.number_ok,
         z.cert_office, z.record_office, z.office_ok, z.cert_classes, z.record_classes, z.classes_ok, z.cert_name, z.name_ok, z.taken, z.confirmed, z.open_corrections,
         z.has_image AND (NOT z.registered OR (z.cert_state = 'match' AND z.confirmed AND z.open_corrections = 0)) AND NOT z.taken
    FROM (SELECT y.*,
                 CASE WHEN NOT y.has_certificate THEN 'none'
                      WHEN y.cert_expiry IS NOT NULL AND y.cert_number IS NULL THEN CASE WHEN y.has_unread THEN 'unread' ELSE 'unclear' END
                      WHEN y.cert_expiry IS NOT NULL THEN CASE WHEN y.expiry_ok AND y.filing_ok AND y.number_ok AND y.office_ok AND y.classes_ok THEN 'match' ELSE 'mismatch' END
                      WHEN y.has_unread THEN 'unread'
                      ELSE 'unclear' END AS cert_state
            FROM (SELECT x.has_image, x.registered, x.has_certificate, x.has_unread, x.record_expiry, x.record_filing, x.record_office, x.record_classes, x.taken, x.open_corrections, COALESCE(c.confirmed, false) AS confirmed,
                         c.expiry_date AS cert_expiry, c.filing_date AS cert_filing,
                         COALESCE(c.application_no, c.registration_no) AS cert_number,
                         c.expiry_date IS NOT NULL AND c.expiry_date IS NOT DISTINCT FROM x.record_expiry AS expiry_ok,
                         c.filing_date IS NULL OR c.filing_date IS NOT DISTINCT FROM x.record_filing AS filing_ok,
                         COALESCE(c.application_no, c.registration_no) IS NOT NULL
                           AND (c.application_no IS NULL OR core.fn_number_key(c.application_no) IN (core.fn_number_key(x.application_no), core.fn_number_key(x.registration_no)))
                           AND (c.registration_no IS NULL OR core.fn_number_key(c.registration_no) IN (core.fn_number_key(x.application_no), core.fn_number_key(x.registration_no))) AS number_ok,
                         c.office_code AS cert_office,
                         c.office_code IS NULL OR c.office_code = x.record_office AS office_ok,
                         c.classes AS cert_classes,
                         c.classes IS NULL OR x.record_classes IS NULL OR c.classes = x.record_classes AS classes_ok,
                         COALESCE(c.mark_text_en, c.mark_text_ar) AS cert_name,
                         CASE WHEN COALESCE(c.key_en, c.key_ar) IS NULL OR COALESCE(x.key_en, x.key_ar) IS NULL THEN NULL
                              ELSE COALESCE(c.key_en IN (x.key_en, x.key_ar), false) OR COALESCE(c.key_ar IN (x.key_en, x.key_ar), false) END AS name_ok
                    FROM (SELECT r.id, r.mark_image_doc_id IS NOT NULL AS has_image, r.expiry_date AS record_expiry, r.filing_date AS record_filing,
                                 r.application_no, r.registration_no, g.code::text AS record_office,
                                 (SELECT array_agg(n.number ORDER BY n.number) FROM core.record_class rc JOIN registry.nice_class n ON n.id = rc.nice_class_id WHERE rc.record_id = r.id) AS record_classes,
                                 NULLIF(core.fn_client_key(r.mark_text ->> 'en'), '') AS key_en, NULLIF(core.fn_client_key(r.mark_text ->> 'ar'), '') AS key_ar,
                                 core.fn_number_taken(r.id) AS taken,
                                 (SELECT count(*)::int FROM core.certificate_correction k WHERE k.record_id = r.id AND k.state IN ('checking', 'held')) AS open_corrections,
                                 (r.registration_no IS NOT NULL OR r.registration_date IS NOT NULL
                                   OR EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type IN ('registered', 'renewed'))) AS registered,
                                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')) AS has_certificate,
                                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')
                                            AND NOT EXISTS (SELECT 1 FROM core.certificate_reading c WHERE c.document_id = d.id)) AS has_unread
                            FROM core.record r JOIN registry.registry g ON g.id = r.registry_id WHERE r.id = p_record_id) x
                    LEFT JOIN LATERAL (SELECT c.expiry_date, c.filing_date, core.fn_number_key(c.application_no) AS application_no, core.fn_number_key(c.registration_no) AS registration_no,
                                              c.office_code, c.classes, c.mark_text_en, c.mark_text_ar, c.confirmed_at IS NOT NULL AS confirmed,
                                              NULLIF(core.fn_client_key(c.mark_text_en), '') AS key_en, NULLIF(core.fn_client_key(c.mark_text_ar), '') AS key_ar
                                         FROM core.certificate_reading c JOIN core.document d ON d.id = c.document_id
                                        WHERE d.record_id = x.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN') AND c.state = 'read'
                                        ORDER BY c.expiry_date DESC, c.read_at DESC LIMIT 1) c ON true) y) z
$$;
GRANT EXECUTE ON FUNCTION core.fn_activation_needs(uuid) TO meesam_app;

-- Fill: a mark that is not active takes its wording and classes from its own certificate. Returns whether anything changed.
CREATE FUNCTION core.fn_certificate_apply(p_record_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
DECLARE n record; c core.certificate_reading; r core.record; v_text jsonb; v_changed boolean := false; k integer;
BEGIN
  PERFORM core.fn_activation_actor();
  SELECT * INTO r FROM core.record WHERE id = p_record_id AND removed_at IS NULL AND activated_at IS NULL AND core.fn_i_hold_record(id) FOR UPDATE;
  IF r.id IS NULL THEN RETURN false; END IF;
  SELECT * INTO n FROM core.fn_activation_needs(p_record_id);
  IF n.number_agrees IS NOT TRUE OR n.office_agrees IS NOT TRUE THEN RETURN false; END IF;
  SELECT * INTO c FROM core.certificate_reading WHERE document_id = core.fn_certificate_in_use(p_record_id);
  IF c.document_id IS NULL THEN RETURN false; END IF;
  v_text := COALESCE(r.mark_text, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('en', c.mark_text_en, 'ar', c.mark_text_ar));
  IF v_text <> '{}'::jsonb AND v_text IS DISTINCT FROM r.mark_text THEN
    UPDATE core.record SET mark_text = v_text WHERE id = r.id;
    UPDATE core.mark_family SET name = v_text WHERE id = r.mark_family_id;
    v_changed := true;
  END IF;
  IF c.classes IS NOT NULL THEN
    DELETE FROM core.record_class rc USING registry.nice_class nc
     WHERE rc.record_id = r.id AND nc.id = rc.nice_class_id AND nc.number <> ALL (c.classes) AND rc.fee_payment_id IS NULL;
    GET DIAGNOSTICS k = ROW_COUNT; v_changed := v_changed OR k > 0;
    INSERT INTO core.record_class (record_id, nice_class_id) SELECT r.id, nc.id FROM registry.nice_class nc WHERE nc.number = ANY (c.classes)
    ON CONFLICT (record_id, nice_class_id) DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; v_changed := v_changed OR k > 0;
  END IF;
  RETURN v_changed;
END $$;

-- The tick. 42501: not allowed; 55000: the certificate does not agree yet, or a correction is open.
CREATE FUNCTION core.fn_certificate_confirm(p_record_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n record;
BEGIN
  PERFORM core.fn_activation_actor();
  IF NOT core.fn_i_hold_record(p_record_id) THEN RAISE EXCEPTION 'not a record this account holds' USING ERRCODE = '42501'; END IF;
  SELECT * INTO n FROM core.fn_activation_needs(p_record_id);
  IF n.certificate_state IS DISTINCT FROM 'match' OR n.corrections_open > 0 THEN
    RAISE EXCEPTION 'the certificate does not agree with the record yet, or a correction is open' USING ERRCODE = '55000';
  END IF;
  UPDATE core.certificate_reading SET confirmed_at = now(), confirmed_by_user_id = platform.current_user_id()
   WHERE document_id = core.fn_certificate_in_use(p_record_id);
END $$;

-- A correction is opened. 22023: no such field or value; 55000: no certificate read, an active mark, or one already open.
CREATE FUNCTION core.fn_certificate_correction_open(p_record_id uuid, p_field text, p_value text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE v_account uuid := core.fn_activation_actor(); c core.certificate_reading; v text := btrim(COALESCE(p_value, '')); v_id uuid; v_was text;
BEGIN
  IF NOT core.fn_i_hold_record(p_record_id) THEN RAISE EXCEPTION 'not a record this account holds' USING ERRCODE = '42501'; END IF;
  IF EXISTS (SELECT 1 FROM core.record WHERE id = p_record_id AND (activated_at IS NOT NULL OR removed_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'corrections are for a trademark that is not active yet' USING ERRCODE = '55000';
  END IF;
  SELECT * INTO c FROM core.certificate_reading WHERE document_id = core.fn_certificate_in_use(p_record_id);
  IF c.document_id IS NULL THEN RAISE EXCEPTION 'no certificate has been read' USING ERRCODE = '55000'; END IF;
  IF p_field IN ('filing_date', 'registration_date', 'expiry_date') THEN
    IF v !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'a date is written YYYY-MM-DD' USING ERRCODE = '22023'; END IF;
    BEGIN PERFORM v::date; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'not a date' USING ERRCODE = '22023'; END;
  ELSIF p_field = 'classes' THEN
    IF v !~ '^\d{1,2}([\s,]+\d{1,2})*$' OR EXISTS (SELECT 1 FROM regexp_split_to_table(v, '[\s,]+') x WHERE x::int NOT BETWEEN 1 AND 45) THEN
      RAISE EXCEPTION 'classes are numbers from 1 to 45' USING ERRCODE = '22023';
    END IF;
    v := (SELECT string_agg(y.n::text, ', ' ORDER BY y.n) FROM (SELECT DISTINCT x::int AS n FROM regexp_split_to_table(v, '[\s,]+') x) y);
  ELSIF p_field NOT IN ('mark_text_en', 'mark_text_ar') OR v = '' OR length(v) > 300 THEN
    RAISE EXCEPTION 'no such field or value' USING ERRCODE = '22023';
  END IF;
  v_was := CASE p_field WHEN 'mark_text_en' THEN c.mark_text_en WHEN 'mark_text_ar' THEN c.mark_text_ar WHEN 'classes' THEN array_to_string(c.classes, ', ')
                        WHEN 'filing_date' THEN c.filing_date::text WHEN 'registration_date' THEN c.registration_date::text ELSE c.expiry_date::text END;
  BEGIN
    INSERT INTO core.certificate_correction (record_id, document_id, account_id, user_id, field, certificate_value, corrected_value)
    VALUES (p_record_id, c.document_id, v_account, platform.current_user_id(), p_field, v_was, v) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'a correction of this field is already open' USING ERRCODE = '55000';
  END;
  UPDATE core.certificate_reading SET confirmed_at = NULL, confirmed_by_user_id = NULL WHERE document_id = c.document_id;
  RETURN v_id;
END $$;

-- The corrected value takes the reading's place (internal; the record follows through fn_certificate_apply and the dates' own path).
CREATE FUNCTION core.fn_certificate_correction_take(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE k core.certificate_correction;
BEGIN
  SELECT * INTO k FROM core.certificate_correction WHERE id = p_id;
  UPDATE core.certificate_reading SET
    mark_text_en      = CASE WHEN k.field = 'mark_text_en' THEN k.corrected_value ELSE mark_text_en END,
    mark_text_ar      = CASE WHEN k.field = 'mark_text_ar' THEN k.corrected_value ELSE mark_text_ar END,
    classes           = CASE WHEN k.field = 'classes' THEN (SELECT array_agg(x::smallint ORDER BY x::smallint) FROM regexp_split_to_table(k.corrected_value, '[\s,]+') x) ELSE classes END,
    filing_date       = CASE WHEN k.field = 'filing_date' THEN k.corrected_value::date ELSE filing_date END,
    registration_date = CASE WHEN k.field = 'registration_date' THEN k.corrected_value::date ELSE registration_date END,
    expiry_date       = CASE WHEN k.field = 'expiry_date' THEN k.corrected_value::date ELSE expiry_date END
   WHERE document_id = k.document_id;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_certificate_correction_take(uuid) FROM PUBLIC;

-- The reader's answer arrives; the publication is looked at here; the correction is accepted or held. Returns the state.
CREATE FUNCTION core.fn_certificate_correction_check(p_id uuid, p_certificate_check text, p_passage text, p_model text DEFAULT NULL,
                                                     p_input_tokens integer DEFAULT NULL, p_output_tokens integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE k core.certificate_correction; p record; v_pub text := 'none'; v_pub_value text; v_state text;
BEGIN
  PERFORM core.fn_activation_actor();
  SELECT * INTO k FROM core.certificate_correction WHERE id = p_id AND state = 'checking' AND account_id = platform.current_account_id() FOR UPDATE;
  IF k.id IS NULL THEN RAISE EXCEPTION 'no such correction waiting for its check' USING ERRCODE = '22023'; END IF;
  -- what the registry published for this record, where it may be shown (0061): the wording and the classes
  SELECT * INTO p FROM core.fn_registry_shows(k.record_id);
  IF FOUND AND k.field IN ('mark_text_en', 'mark_text_ar') AND NULLIF(core.fn_client_key(p.mark_text ->> right(k.field, 2)), '') IS NOT NULL THEN
    v_pub_value := p.mark_text ->> right(k.field, 2);
    v_pub := CASE WHEN core.fn_client_key(v_pub_value) = core.fn_client_key(k.corrected_value) THEN 'supports' ELSE 'contradicts' END;
  ELSIF FOUND AND k.field = 'classes' AND cardinality(p.classes) > 0 THEN
    v_pub_value := (SELECT string_agg(x::text, ', ' ORDER BY x) FROM unnest(p.classes) x);
    v_pub := CASE WHEN v_pub_value = k.corrected_value THEN 'supports' ELSE 'contradicts' END;
  END IF;
  v_state := CASE WHEN p_certificate_check = 'supports' AND v_pub <> 'contradicts' THEN 'accepted' ELSE 'held' END;
  UPDATE core.certificate_correction SET state = v_state, certificate_check = p_certificate_check, certificate_passage = left(p_passage, 300), published_check = v_pub,
         published_value = left(v_pub_value, 300), model = left(p_model, 80), input_tokens = p_input_tokens, output_tokens = p_output_tokens, updated_at = now()
   WHERE id = k.id;
  IF v_state = 'accepted' THEN PERFORM core.fn_certificate_correction_take(k.id); END IF;
  RETURN v_state;
END $$;

-- The account takes its open correction back.
CREATE FUNCTION core.fn_certificate_correction_withdraw(p_id uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM core.fn_activation_actor();
  UPDATE core.certificate_correction SET state = 'withdrawn', updated_at = now()
   WHERE id = p_id AND state IN ('checking', 'held') AND core.fn_i_hold_record(record_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END $$;

-- Who is told that a correction is held: Meesam's System Administrators and the person who entered it.
CREATE FUNCTION core.fn_certificate_correction_alert(p_id uuid) RETURNS TABLE (email text, name text, locale text, staff boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT u.email::text, u.name, u.locale, true
    FROM core.certificate_correction k, core.app_user u JOIN core.account a ON a.id = u.account_id AND a.is_staff
   WHERE k.id = p_id AND k.state = 'held' AND k.account_id = platform.current_account_id()
     AND u.status = 'active' AND EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = u.id AND s.role = 'system_admin')
  UNION ALL
  SELECT u.email::text, u.name, u.locale, false
    FROM core.certificate_correction k JOIN core.app_user u ON u.id = k.user_id
   WHERE k.id = p_id AND k.state = 'held' AND k.account_id = platform.current_account_id()
$$;

REVOKE EXECUTE ON FUNCTION core.fn_certificate_in_use(uuid), core.fn_certificate_apply(uuid), core.fn_certificate_confirm(uuid), core.fn_certificate_correction_open(uuid, text, text),
                           core.fn_certificate_correction_check(uuid, text, text, text, integer, integer), core.fn_certificate_correction_withdraw(uuid), core.fn_certificate_correction_alert(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_certificate_in_use(uuid), core.fn_certificate_apply(uuid), core.fn_certificate_confirm(uuid), core.fn_certificate_correction_open(uuid, text, text),
                          core.fn_certificate_correction_check(uuid, text, text, text, integer, integer), core.fn_certificate_correction_withdraw(uuid), core.fn_certificate_correction_alert(uuid) TO meesam_app;

-- System Admin: the corrections that are held, oldest first.
CREATE FUNCTION platform.fn_certificate_corrections()
RETURNS TABLE (id uuid, created_at timestamptz, account jsonb, user_name text, user_email text, registry_code text, number text, mark_text jsonb, field text,
               certificate_value text, corrected_value text, certificate_check text, certificate_passage text, published_check text, published_value text, document_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, public, pg_temp AS $$
  SELECT k.id, k.created_at, a.name, u.name, u.email::text, g.code::text, COALESCE(r.registration_no, r.application_no), r.mark_text, k.field,
         k.certificate_value, k.corrected_value, k.certificate_check, k.certificate_passage, k.published_check, k.published_value, k.document_id
    FROM core.certificate_correction k JOIN core.record r ON r.id = k.record_id JOIN registry.registry g ON g.id = r.registry_id
    JOIN core.account a ON a.id = k.account_id JOIN core.app_user u ON u.id = k.user_id
   WHERE k.state = 'held' AND r.removed_at IS NULL
   ORDER BY k.created_at
$$;

-- System Admin settles one: accepted (the reading carries the corrected value; the account then confirms) or rejected.
-- Returns whom to tell. The record itself is not written to by staff.
CREATE FUNCTION platform.fn_certificate_correction_settle(p_id uuid, p_accept boolean, p_note text, p_by uuid)
RETURNS TABLE (email text, name text, locale text, record_id uuid, field text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE k core.certificate_correction;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform.staff_role s WHERE s.user_id = p_by AND s.role = 'system_admin') THEN
    RAISE EXCEPTION 'System Administrators only' USING ERRCODE = '42501';
  END IF;
  UPDATE core.certificate_correction c SET state = CASE WHEN p_accept THEN 'accepted' ELSE 'rejected' END, settled_by_user_id = p_by,
         settled_note = left(NULLIF(btrim(p_note), ''), 300), settled_at = now(), updated_at = now()
   WHERE c.id = p_id AND c.state = 'held' RETURNING c.* INTO k;
  IF k.id IS NULL THEN RAISE EXCEPTION 'no such correction waiting' USING ERRCODE = '22023'; END IF;
  IF p_accept THEN PERFORM core.fn_certificate_correction_take(k.id); END IF;
  RETURN QUERY SELECT u.email::text, u.name, u.locale, k.record_id, k.field FROM core.app_user u WHERE u.id = k.user_id;
END $$;

-- The certificate a held correction is about, for the administrator who settles it.
CREATE FUNCTION platform.fn_certificate_correction_file(p_id uuid, OUT object_key text, OUT file_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT d.object_key, d.file_name FROM core.certificate_correction k JOIN core.document d ON d.id = k.document_id WHERE k.id = p_id AND k.state = 'held'
$$;

-- What the certificate reader has used (for the cost report): readings and correction checks, by month.
CREATE FUNCTION platform.fn_certificate_reader_usage()
RETURNS TABLE (month date, readings integer, checks integer, input_tokens bigint, output_tokens bigint, model text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
  SELECT date_trunc('month', x.at)::date, count(*) FILTER (WHERE x.kind = 'r')::int, count(*) FILTER (WHERE x.kind = 'c')::int,
         COALESCE(sum(x.i), 0)::bigint, COALESCE(sum(x.o), 0)::bigint, x.model
    FROM (SELECT 'r' AS kind, read_at AS at, input_tokens AS i, output_tokens AS o, model FROM core.certificate_reading
          UNION ALL
          SELECT 'c', created_at, input_tokens, output_tokens, model FROM core.certificate_correction WHERE certificate_check IS NOT NULL) x
   GROUP BY 1, x.model ORDER BY 1 DESC, x.model
$$;

REVOKE EXECUTE ON FUNCTION platform.fn_certificate_corrections(), platform.fn_certificate_correction_settle(uuid, boolean, text, uuid),
                           platform.fn_certificate_correction_file(uuid), platform.fn_certificate_reader_usage() FROM PUBLIC, meesam_app;
GRANT EXECUTE ON FUNCTION platform.fn_certificate_corrections(), platform.fn_certificate_correction_settle(uuid, boolean, text, uuid),
                          platform.fn_certificate_correction_file(uuid), platform.fn_certificate_reader_usage() TO meesam_staff, meesam_admin;

COMMIT;
