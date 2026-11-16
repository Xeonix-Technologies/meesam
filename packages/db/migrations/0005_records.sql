-- =============================================================================
-- Meesam — migration 0005: existing-mark intake, vault naming, stage changes (Step 3.4)
-- Sources: System Description 4.7 (intake, 24 Oct / 10 Nov 2026), item 43 (vault naming),
-- item 37/42 (record page), Owner 3.3–3.7 and Agency 3.3–3.7.
-- =============================================================================
BEGIN;

-- Intake runs over several screens with uploads in between; the draft lives here until step 7
-- (review and accept) creates the record. Abandoned drafts are swept by housekeeping after 30 days.
CREATE TYPE core.draft_status AS ENUM ('open', 'committed', 'abandoned');
CREATE TABLE core.intake_draft (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid NOT NULL REFERENCES core.account(id),
  user_id     uuid NOT NULL REFERENCES core.app_user(id),
  kind        text NOT NULL DEFAULT 'existing',          -- existing | filing (Section 6, Step 3.5)
  step        smallint NOT NULL DEFAULT 1,
  data        jsonb NOT NULL DEFAULT '{}'::jsonb,         -- the answers so far, by step
  uploads     jsonb NOT NULL DEFAULT '[]'::jsonb,         -- [{object_key, doc_type, file_name, content_type, size, sha256}]
  warnings    jsonb NOT NULL DEFAULT '[]'::jsonb,         -- advisory checks at review, with the user's confirmations
  status      core.draft_status NOT NULL DEFAULT 'open',
  record_id   uuid NULL REFERENCES core.record(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.intake_draft (account_id, status, updated_at DESC);
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON core.intake_draft FOR EACH ROW EXECUTE FUNCTION platform.touch_updated_at();
ALTER TABLE core.intake_draft ENABLE ROW LEVEL SECURITY;
CREATE POLICY intake_draft_all ON core.intake_draft FOR ALL TO meesam_app
  USING (account_id = platform.current_account_id()) WITH CHECK (account_id = platform.current_account_id());
GRANT SELECT, INSERT, UPDATE ON core.intake_draft TO meesam_app;

-- Vault object key (item 43): regno_serial_DDMMYY_TYPE.ext; an empty part stays empty.
CREATE OR REPLACE FUNCTION core.fn_vault_key(p_registration_no text, p_application_no text, p_date date, p_doc_type text, p_ext text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT format('%s_%s_%s_%s.%s',
                regexp_replace(COALESCE(p_registration_no, ''), '[^A-Za-z0-9-]', '', 'g'),
                regexp_replace(COALESCE(p_application_no, ''), '[^A-Za-z0-9-]', '', 'g'),
                to_char(p_date, 'DDMMYY'), upper(p_doc_type), lower(regexp_replace(p_ext, '[^A-Za-z0-9]', '', 'g')))
$$;

-- Next serial for a record's documents of one type (second POA → serial_no '2'), used in the key when a name collides.
CREATE OR REPLACE FUNCTION core.fn_next_doc_serial(p_record_id uuid, p_doc_type text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT (count(*) + 1)::text FROM core.document WHERE record_id = p_record_id AND doc_type = p_doc_type
$$;

-- Clocks that were already over when an existing mark is loaded (e.g. the opposition window of a
-- mark that is now registered) are closed as met, so the record shows only live dates.
-- RULING NEEDED: "met" vs a distinct "historical" state for clocks closed by loading history.
CREATE OR REPLACE FUNCTION core.fn_close_historical_timers(p_record_id uuid, p_as_of date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE core.timer SET state = 'met', met_at = now()
   WHERE record_id = p_record_id AND state = 'open' AND due_date IS NOT NULL AND due_date < p_as_of
     AND family = 'statutory' AND timer_type IN ('oppose', 'counterstatement', 'pay_registration', 'appeal', 'priority_document');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Portfolio export / dashboard helpers run under RLS (security_invoker views).
CREATE OR REPLACE VIEW core.v_next_dates WITH (security_invoker = true) AS
  SELECT t.id AS timer_id, t.record_id, t.timer_type, t.family, t.due_date, t.due_at, t.awaiting_user_entry,
         (t.due_date - current_date) AS days_remaining,
         r.mark_text, r.registry_id, g.code AS registry_code, r.agent_of_record_account_id,
         (SELECT a.agency_account_id FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id
           WHERE ar.record_id = r.id AND ar.removed_at IS NULL AND a.status = 'accepted' AND a.ended_at IS NULL LIMIT 1) AS holding_agency_id
    FROM core.timer t JOIN core.record r ON r.id = t.record_id JOIN registry.registry g ON g.id = r.registry_id
   WHERE t.state = 'open';

GRANT SELECT ON core.v_next_dates, core.v_record_state, core.v_record_access TO meesam_app, meesam_staff, meesam_readonly;
GRANT EXECUTE ON FUNCTION core.fn_vault_key(text, text, date, text, text), core.fn_next_doc_serial(uuid, text), core.fn_close_historical_timers(uuid, date) TO meesam_app, meesam_worker, meesam_admin;

-- Housekeeping sweep for abandoned drafts (called by the worker's housekeeping job).
CREATE OR REPLACE FUNCTION core.fn_sweep_intake_drafts(p_older_than interval DEFAULT interval '30 days') RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE core.intake_draft SET status = 'abandoned' WHERE status = 'open' AND updated_at < now() - p_older_than;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
GRANT EXECUTE ON FUNCTION core.fn_sweep_intake_drafts(interval) TO meesam_worker, meesam_admin;

COMMIT;
