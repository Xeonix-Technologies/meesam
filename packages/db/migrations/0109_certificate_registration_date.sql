-- 0109 — The registration date read from a certificate is kept with the reading.
-- Founder, 28 Nov 2026: "the Certificate information is not updated from the document read". When a certificate's
-- number is the record's, the record's dates are taken from the certificate. That can happen later than the
-- reading itself (the account first corrects the number on the Certificate tab), so the registration date has to
-- be kept too, beside the filing and expiry dates already kept (0106, 0107).
BEGIN;

ALTER TABLE core.certificate_reading ADD COLUMN registration_date date NULL;

DROP FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer);
CREATE FUNCTION core.fn_certificate_reading_set(p_document_id uuid, p_expiry date, p_filing date, p_application_no text, p_registration_no text,
                                                p_confidence numeric, p_source text, p_model text,
                                                p_input_tokens integer DEFAULT NULL, p_output_tokens integer DEFAULT NULL,
                                                p_registration_date date DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE d core.document%ROWTYPE; v_state text := CASE WHEN p_expiry IS NULL THEN 'unclear' ELSE 'read' END;
BEGIN
  SELECT * INTO d FROM core.document WHERE id = p_document_id AND removed_at IS NULL AND doc_type IN ('ORC', 'REN');
  IF NOT FOUND OR NOT core.fn_i_hold_record(d.record_id) THEN
    RAISE EXCEPTION 'not a certificate of a record this account holds' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, filing_date, registration_date, application_no, registration_no, confidence, source, model, input_tokens, output_tokens, read_by_user_id)
  VALUES (p_document_id, d.record_id, v_state, p_expiry, p_filing, p_registration_date, left(NULLIF(btrim(p_application_no), ''), 60), left(NULLIF(btrim(p_registration_no), ''), 60),
          LEAST(1, GREATEST(0, p_confidence)), left(p_source, 300), left(p_model, 80), p_input_tokens, p_output_tokens, platform.current_user_id())
  ON CONFLICT (document_id) DO UPDATE SET state = EXCLUDED.state, expiry_date = EXCLUDED.expiry_date, filing_date = EXCLUDED.filing_date, registration_date = EXCLUDED.registration_date,
    application_no = EXCLUDED.application_no, registration_no = EXCLUDED.registration_no, confidence = EXCLUDED.confidence,
    source = EXCLUDED.source, model = EXCLUDED.model, input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens, read_at = now(), read_by_user_id = EXCLUDED.read_by_user_id;
  RETURN v_state;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, date, text, text, numeric, text, text, integer, integer, date) TO meesam_app;

-- The dates the certificate that counts gives for a record (the one with the latest expiry date read, as in
-- fn_activation_needs). Runs as the caller: only for a record the caller can see.
CREATE FUNCTION core.fn_certificate_dates(p_record_id uuid, OUT filing_date date, OUT registration_date date, OUT expiry_date date)
LANGUAGE sql STABLE AS $$
  SELECT c.filing_date, c.registration_date, c.expiry_date
    FROM core.certificate_reading c JOIN core.document d ON d.id = c.document_id
   WHERE d.record_id = p_record_id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN') AND c.state = 'read'
   ORDER BY c.expiry_date DESC, c.read_at DESC LIMIT 1
$$;
GRANT EXECUTE ON FUNCTION core.fn_certificate_dates(uuid) TO meesam_app;

COMMIT;
