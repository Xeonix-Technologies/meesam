-- 0108 — The certificate's numbers are read and matched (Founder ruling 28 Nov 2026: "Meesam should compare the
-- registration and the application number, so that no one certificate is used in two or more records").
-- The reader already reports the application number and the registration number printed on a certificate; they
-- are now kept with the reading. A registered mark is ready for activation only when, besides the two dates
-- (0106, 0107), every number the certificate gives is one of the record's own two numbers. Offices differ in
-- which of the two a number is called, and an account may have typed it in either field, so a number read from
-- the certificate is accepted in either place. Numbers are compared without spaces, punctuation or letter case.
-- A certificate on which no number at all could be made out cannot be tied to a record: it counts as not clear
-- and a clearer copy is asked for. Because a registry's number belongs to one record only (the record table's
-- own unique rule), one certificate can then serve one record only.
-- Readings made before today carry no numbers (and those before 0107 no filing date): they are cleared here, so
-- that those certificates read again in full. On production there are none.
BEGIN;

-- numbers are compared through core.fn_number_key (0061): letters and digits only, upper case
ALTER TABLE core.certificate_reading ADD COLUMN application_no text NULL, ADD COLUMN registration_no text NULL;
DELETE FROM core.certificate_reading;

DROP FUNCTION core.fn_certificate_reading_set(uuid, date, date, numeric, text, text, integer, integer);
CREATE FUNCTION core.fn_certificate_reading_set(p_document_id uuid, p_expiry date, p_filing date, p_application_no text, p_registration_no text,
                                                p_confidence numeric, p_source text, p_model text,
                                                p_input_tokens integer DEFAULT NULL, p_output_tokens integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE d core.document%ROWTYPE; v_state text := CASE WHEN p_expiry IS NULL THEN 'unclear' ELSE 'read' END;
BEGIN
  SELECT * INTO d FROM core.document WHERE id = p_document_id AND removed_at IS NULL AND doc_type IN ('ORC', 'REN');
  IF NOT FOUND OR NOT core.fn_i_hold_record(d.record_id) THEN
    RAISE EXCEPTION 'not a certificate of a record this account holds' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, filing_date, application_no, registration_no, confidence, source, model, input_tokens, output_tokens, read_by_user_id)
  VALUES (p_document_id, d.record_id, v_state, p_expiry, p_filing, left(NULLIF(btrim(p_application_no), ''), 60), left(NULLIF(btrim(p_registration_no), ''), 60),
          LEAST(1, GREATEST(0, p_confidence)), left(p_source, 300), left(p_model, 80), p_input_tokens, p_output_tokens, platform.current_user_id())
  ON CONFLICT (document_id) DO UPDATE SET state = EXCLUDED.state, expiry_date = EXCLUDED.expiry_date, filing_date = EXCLUDED.filing_date,
    application_no = EXCLUDED.application_no, registration_no = EXCLUDED.registration_no, confidence = EXCLUDED.confidence,
    source = EXCLUDED.source, model = EXCLUDED.model, input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens, read_at = now(), read_by_user_id = EXCLUDED.read_by_user_id;
  RETURN v_state;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer) TO meesam_app;

-- As 0107, with the numbers. certificate_number is the number the certificate gives (its application number, or its
-- registration number where it gives no other); number_agrees says whether every number it gives is one of the record's.
DROP FUNCTION core.fn_activation_needs(uuid);
CREATE FUNCTION core.fn_activation_needs(p_record_id uuid, OUT has_image boolean, OUT needs_certificate boolean, OUT has_certificate boolean,
                                         OUT certificate_state text, OUT certificate_expiry date, OUT record_expiry date,
                                         OUT certificate_filing date, OUT record_filing date, OUT expiry_agrees boolean, OUT filing_agrees boolean,
                                         OUT certificate_number text, OUT number_agrees boolean, OUT ready boolean)
LANGUAGE sql STABLE AS $$
  SELECT z.has_image, z.registered, z.has_certificate,
         CASE WHEN NOT z.registered THEN NULL ELSE z.cert_state END,
         z.cert_expiry, z.record_expiry, z.cert_filing, z.record_filing, z.expiry_ok, z.filing_ok, z.cert_number, z.number_ok,
         z.has_image AND (NOT z.registered OR z.cert_state = 'match')
    FROM (SELECT y.*,
                 CASE WHEN NOT y.has_certificate THEN 'none'
                      WHEN y.cert_expiry IS NOT NULL AND y.cert_number IS NULL THEN CASE WHEN y.has_unread THEN 'unread' ELSE 'unclear' END
                      WHEN y.cert_expiry IS NOT NULL THEN CASE WHEN y.expiry_ok AND y.filing_ok AND y.number_ok THEN 'match' ELSE 'mismatch' END
                      WHEN y.has_unread THEN 'unread'
                      ELSE 'unclear' END AS cert_state
            FROM (SELECT x.has_image, x.registered, x.has_certificate, x.has_unread, x.record_expiry, x.record_filing,
                         c.expiry_date AS cert_expiry, c.filing_date AS cert_filing,
                         COALESCE(c.application_no, c.registration_no) AS cert_number,
                         c.expiry_date IS NOT NULL AND c.expiry_date IS NOT DISTINCT FROM x.record_expiry AS expiry_ok,
                         c.filing_date IS NULL OR c.filing_date IS NOT DISTINCT FROM x.record_filing AS filing_ok,
                         COALESCE(c.application_no, c.registration_no) IS NOT NULL
                           AND (c.application_no IS NULL OR core.fn_number_key(c.application_no) IN (core.fn_number_key(x.application_no), core.fn_number_key(x.registration_no)))
                           AND (c.registration_no IS NULL OR core.fn_number_key(c.registration_no) IN (core.fn_number_key(x.application_no), core.fn_number_key(x.registration_no))) AS number_ok
                    FROM (SELECT r.id, r.mark_image_doc_id IS NOT NULL AS has_image, r.expiry_date AS record_expiry, r.filing_date AS record_filing,
                                 r.application_no, r.registration_no,
                                 (r.registration_no IS NOT NULL OR r.registration_date IS NOT NULL
                                   OR EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type IN ('registered', 'renewed'))) AS registered,
                                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')) AS has_certificate,
                                 EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')
                                            AND NOT EXISTS (SELECT 1 FROM core.certificate_reading c WHERE c.document_id = d.id)) AS has_unread
                            FROM core.record r WHERE r.id = p_record_id) x
                    LEFT JOIN LATERAL (SELECT c.expiry_date, c.filing_date, core.fn_number_key(c.application_no) AS application_no, core.fn_number_key(c.registration_no) AS registration_no
                                         FROM core.certificate_reading c JOIN core.document d ON d.id = c.document_id
                                        WHERE d.record_id = x.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN') AND c.state = 'read'
                                        ORDER BY c.expiry_date DESC, c.read_at DESC LIMIT 1) c ON true) y) z
$$;
GRANT EXECUTE ON FUNCTION core.fn_activation_needs(uuid) TO meesam_app;

COMMIT;
