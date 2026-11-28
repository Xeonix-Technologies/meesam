-- 0112 — The certificate's issuing office and classes are matched; its mark name is a warning
-- (Founder ruling 28 Nov 2026: "not only the certificate number should be compared, as numbers might be the same
-- in different registries, and the name might be the same mark with different certificates, one for each class").
-- The reader already reports the issuing office (its WIPO ST.3 code), the Nice classes and the mark's wording;
-- they are now kept with the reading. A registered mark is ready for activation only when, besides the number and
-- the two dates (0106 to 0108):
--   * the office that issued the certificate is the record's registry;
--   * the classes on the certificate are the record's classes.
-- The mark's name is compared too, as a note only and never a bar: names are printed inside logos, in two
-- scripts, or spelled differently, and a bar would stop correct certificates.
-- Narrowest reading, each a question for the Founder (docs/README.md): an office or classes the reader could not
-- make out are not held against the certificate (as with a filing date it does not print, 0107), and a record
-- with no class entered has nothing to disagree with.
-- The record's dates are still taken from the certificate only when it is this record's certificate (the
-- application does that); a certificate of another office or another class fills nothing.
-- Also here: number_taken, from 0111, so that the record's page can say that its number is active elsewhere.
-- Readings made before today carry no office, classes or name: they are cleared, so that those certificates are
-- read again in full. On production there are none.
BEGIN;

ALTER TABLE core.certificate_reading
  ADD COLUMN office_code  text NULL CHECK (office_code ~ '^[A-Z]{2}$'),
  ADD COLUMN classes      smallint[] NULL,
  ADD COLUMN mark_text_ar text NULL,
  ADD COLUMN mark_text_en text NULL;
DELETE FROM core.certificate_reading;

DROP FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer, date);
CREATE FUNCTION core.fn_certificate_reading_set(p_document_id uuid, p_expiry date, p_filing date, p_application_no text, p_registration_no text,
                                                p_confidence numeric, p_source text, p_model text,
                                                p_input_tokens integer DEFAULT NULL, p_output_tokens integer DEFAULT NULL,
                                                p_registration_date date DEFAULT NULL, p_office text DEFAULT NULL, p_classes smallint[] DEFAULT NULL,
                                                p_mark_ar text DEFAULT NULL, p_mark_en text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE d core.document%ROWTYPE; v_state text := CASE WHEN p_expiry IS NULL THEN 'unclear' ELSE 'read' END;
        v_office text := CASE WHEN upper(btrim(p_office)) ~ '^[A-Z]{2}$' THEN upper(btrim(p_office)) END;
        v_classes smallint[] := (SELECT array_agg(DISTINCT c ORDER BY c) FROM unnest(p_classes) c WHERE c BETWEEN 1 AND 45);
BEGIN
  SELECT * INTO d FROM core.document WHERE id = p_document_id AND removed_at IS NULL AND doc_type IN ('ORC', 'REN');
  IF NOT FOUND OR NOT core.fn_i_hold_record(d.record_id) THEN
    RAISE EXCEPTION 'not a certificate of a record this account holds' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, filing_date, registration_date, application_no, registration_no, office_code, classes, mark_text_ar, mark_text_en,
                                        confidence, source, model, input_tokens, output_tokens, read_by_user_id)
  VALUES (p_document_id, d.record_id, v_state, p_expiry, p_filing, p_registration_date, left(NULLIF(btrim(p_application_no), ''), 60), left(NULLIF(btrim(p_registration_no), ''), 60),
          v_office, v_classes, left(NULLIF(btrim(p_mark_ar), ''), 300), left(NULLIF(btrim(p_mark_en), ''), 300),
          LEAST(1, GREATEST(0, p_confidence)), left(p_source, 300), left(p_model, 80), p_input_tokens, p_output_tokens, platform.current_user_id())
  ON CONFLICT (document_id) DO UPDATE SET state = EXCLUDED.state, expiry_date = EXCLUDED.expiry_date, filing_date = EXCLUDED.filing_date, registration_date = EXCLUDED.registration_date,
    application_no = EXCLUDED.application_no, registration_no = EXCLUDED.registration_no, office_code = EXCLUDED.office_code, classes = EXCLUDED.classes,
    mark_text_ar = EXCLUDED.mark_text_ar, mark_text_en = EXCLUDED.mark_text_en, confidence = EXCLUDED.confidence,
    source = EXCLUDED.source, model = EXCLUDED.model, input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens, read_at = now(), read_by_user_id = EXCLUDED.read_by_user_id;
  RETURN v_state;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer, date, text, smallint[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer, date, text, smallint[], text, text) TO meesam_app;

-- As 0108, with the office, the classes, the name and number_taken.
-- name_agrees: NULL when one side has no name to compare; names are compared without letter case, spaces or punctuation.
DROP FUNCTION core.fn_activation_needs(uuid);
CREATE FUNCTION core.fn_activation_needs(p_record_id uuid, OUT has_image boolean, OUT needs_certificate boolean, OUT has_certificate boolean,
                                         OUT certificate_state text, OUT certificate_expiry date, OUT record_expiry date,
                                         OUT certificate_filing date, OUT record_filing date, OUT expiry_agrees boolean, OUT filing_agrees boolean,
                                         OUT certificate_number text, OUT number_agrees boolean,
                                         OUT certificate_office text, OUT record_office text, OUT office_agrees boolean,
                                         OUT certificate_classes smallint[], OUT record_classes smallint[], OUT classes_agree boolean,
                                         OUT certificate_name text, OUT name_agrees boolean, OUT number_taken boolean, OUT ready boolean)
LANGUAGE sql STABLE AS $$
  SELECT z.has_image, z.registered, z.has_certificate,
         CASE WHEN NOT z.registered THEN NULL ELSE z.cert_state END,
         z.cert_expiry, z.record_expiry, z.cert_filing, z.record_filing, z.expiry_ok, z.filing_ok, z.cert_number, z.number_ok,
         z.cert_office, z.record_office, z.office_ok, z.cert_classes, z.record_classes, z.classes_ok, z.cert_name, z.name_ok, z.taken,
         z.has_image AND (NOT z.registered OR z.cert_state = 'match') AND NOT z.taken
    FROM (SELECT y.*,
                 CASE WHEN NOT y.has_certificate THEN 'none'
                      WHEN y.cert_expiry IS NOT NULL AND y.cert_number IS NULL THEN CASE WHEN y.has_unread THEN 'unread' ELSE 'unclear' END
                      WHEN y.cert_expiry IS NOT NULL THEN CASE WHEN y.expiry_ok AND y.filing_ok AND y.number_ok AND y.office_ok AND y.classes_ok THEN 'match' ELSE 'mismatch' END
                      WHEN y.has_unread THEN 'unread'
                      ELSE 'unclear' END AS cert_state
            FROM (SELECT x.has_image, x.registered, x.has_certificate, x.has_unread, x.record_expiry, x.record_filing, x.record_office, x.record_classes, x.taken,
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
                                 (r.registration_no IS NOT NULL OR r.registration_date IS NOT NULL
                                   OR EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type IN ('registered', 'renewed'))) AS registered,
                                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')) AS has_certificate,
                                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')
                                            AND NOT EXISTS (SELECT 1 FROM core.certificate_reading c WHERE c.document_id = d.id)) AS has_unread
                            FROM core.record r JOIN registry.registry g ON g.id = r.registry_id WHERE r.id = p_record_id) x
                    LEFT JOIN LATERAL (SELECT c.expiry_date, c.filing_date, core.fn_number_key(c.application_no) AS application_no, core.fn_number_key(c.registration_no) AS registration_no,
                                              c.office_code, c.classes, c.mark_text_en, c.mark_text_ar,
                                              NULLIF(core.fn_client_key(c.mark_text_en), '') AS key_en, NULLIF(core.fn_client_key(c.mark_text_ar), '') AS key_ar
                                         FROM core.certificate_reading c JOIN core.document d ON d.id = c.document_id
                                        WHERE d.record_id = x.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN') AND c.state = 'read'
                                        ORDER BY c.expiry_date DESC, c.read_at DESC LIMIT 1) c ON true) y) z
$$;
GRANT EXECUTE ON FUNCTION core.fn_activation_needs(uuid) TO meesam_app;

COMMIT;
