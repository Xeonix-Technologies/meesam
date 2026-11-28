-- 0106 — Meesam reads the certificate; activation waits until its expiry date and the record's agree
-- (Founder ruling 28 Nov 2026: option B, "Meesam reads the certificate"; "if the certificate is not clear,
-- Meesam asks for a clearer one").
-- The fee is calculated from the expiry date, so the date typed on the record is checked against the date printed
-- on the certificate. Each certificate on a record (a document filed as Registration certificate, ORC, or Renewal
-- certificate, REN) is read once by the document reader; what it found is kept here. For a registered mark:
--   * no certificate                                  -> activation asks for it (as 0105);
--   * a certificate not read yet                      -> activation waits for the reading;
--   * read, but no expiry date could be made out      -> Meesam asks for a clearer copy;
--   * read, and the date differs from the record's    -> the account corrects the record's date (or adds the right certificate);
--   * read, and the dates agree                       -> ready.
-- With several certificates the latest expiry date read counts: a renewal certificate supersedes the first one.
-- The reading itself is done by the web service (the reader's key is its configuration); this migration keeps the
-- result and decides. A reading never changes the record: what the account typed stays the account's (rule 13).
BEGIN;

CREATE TABLE core.certificate_reading (
  document_id   uuid PRIMARY KEY REFERENCES core.document(id),
  record_id     uuid NOT NULL REFERENCES core.record(id),
  state         text NOT NULL CHECK (state IN ('read', 'unclear')),
  expiry_date   date NULL,
  confidence    numeric(4,3) NULL CHECK (confidence BETWEEN 0 AND 1),
  source        text NULL,                 -- the passage of the document the date came from
  model         text NULL,
  input_tokens  integer NULL,              -- what the reading used, for the cost report
  output_tokens integer NULL,
  read_at       timestamptz NOT NULL DEFAULT now(),
  read_by_user_id uuid NULL REFERENCES core.app_user(id),
  CHECK ((state = 'read') = (expiry_date IS NOT NULL))
);
CREATE INDEX ON core.certificate_reading (record_id);
ALTER TABLE core.certificate_reading ENABLE ROW LEVEL SECURITY;
-- seen by whoever sees the document it belongs to (the document's own policy decides)
CREATE POLICY certificate_reading_select ON core.certificate_reading FOR SELECT TO meesam_app
  USING (EXISTS (SELECT 1 FROM core.document d WHERE d.id = document_id));
GRANT SELECT ON core.certificate_reading TO meesam_app, meesam_admin, meesam_readonly;
CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON core.certificate_reading FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row();

-- Keeps what the reader found on one certificate. The caller must hold the record; the document must be a
-- certificate of that record. Reading again replaces the earlier result.
CREATE FUNCTION core.fn_certificate_reading_set(p_document_id uuid, p_expiry date, p_confidence numeric, p_source text, p_model text,
                                                p_input_tokens integer DEFAULT NULL, p_output_tokens integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, public, pg_temp AS $$
DECLARE d core.document%ROWTYPE; v_state text := CASE WHEN p_expiry IS NULL THEN 'unclear' ELSE 'read' END;
BEGIN
  SELECT * INTO d FROM core.document WHERE id = p_document_id AND removed_at IS NULL AND doc_type IN ('ORC', 'REN');
  IF NOT FOUND OR NOT core.fn_i_hold_record(d.record_id) THEN
    RAISE EXCEPTION 'not a certificate of a record this account holds' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO core.certificate_reading (document_id, record_id, state, expiry_date, confidence, source, model, input_tokens, output_tokens, read_by_user_id)
  VALUES (p_document_id, d.record_id, v_state, p_expiry, LEAST(1, GREATEST(0, p_confidence)), left(p_source, 300), left(p_model, 80), p_input_tokens, p_output_tokens, platform.current_user_id())
  ON CONFLICT (document_id) DO UPDATE SET state = EXCLUDED.state, expiry_date = EXCLUDED.expiry_date, confidence = EXCLUDED.confidence, source = EXCLUDED.source,
    model = EXCLUDED.model, input_tokens = EXCLUDED.input_tokens, output_tokens = EXCLUDED.output_tokens, read_at = now(), read_by_user_id = EXCLUDED.read_by_user_id;
  RETURN v_state;
END $$;
REVOKE EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, numeric, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.fn_certificate_reading_set(uuid, date, numeric, text, text, integer, integer) TO meesam_app;

-- What activation asks of one record and what it has, now with the certificate's state:
--   none | unread | unclear | mismatch | match   (NULL where no certificate is needed)
DROP FUNCTION core.fn_activation_needs(uuid);
CREATE FUNCTION core.fn_activation_needs(p_record_id uuid, OUT has_image boolean, OUT needs_certificate boolean, OUT has_certificate boolean,
                                         OUT certificate_state text, OUT certificate_expiry date, OUT record_expiry date, OUT ready boolean)
LANGUAGE sql STABLE AS $$
  SELECT y.has_image, y.registered, y.has_certificate,
         CASE WHEN NOT y.registered THEN NULL ELSE y.cert_state END,
         y.cert_expiry, y.record_expiry,
         y.has_image AND (NOT y.registered OR y.cert_state = 'match')
    FROM (SELECT x.*,
                 CASE WHEN NOT x.has_certificate THEN 'none'
                      WHEN x.cert_expiry IS NOT NULL THEN CASE WHEN x.cert_expiry = x.record_expiry THEN 'match' ELSE 'mismatch' END
                      WHEN x.has_unread THEN 'unread'
                      ELSE 'unclear' END AS cert_state
            FROM (SELECT r.mark_image_doc_id IS NOT NULL AS has_image, r.expiry_date AS record_expiry,
                         (r.registration_no IS NOT NULL OR r.registration_date IS NOT NULL
                           OR EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type IN ('registered', 'renewed'))) AS registered,
                         EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')) AS has_certificate,
                         EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')
                                    AND NOT EXISTS (SELECT 1 FROM core.certificate_reading c WHERE c.document_id = d.id)) AS has_unread,
                         (SELECT max(c.expiry_date) FROM core.certificate_reading c JOIN core.document d ON d.id = c.document_id
                           WHERE d.record_id = r.id AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN') AND c.state = 'read') AS cert_expiry
                    FROM core.record r WHERE r.id = p_record_id) x) y
$$;
GRANT EXECUTE ON FUNCTION core.fn_activation_needs(uuid) TO meesam_app;

COMMIT;
