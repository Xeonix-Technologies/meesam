-- =============================================================================
-- Meesam (ميسم) — migration 0001: core schema
-- Source of truth: docs/01-product/MSM — Data Architecture v0.2 (12 Nov 2026),
-- Sections 5–12 and 14; System Description v0.4 items 37–45; Business Model v0.1
-- Section 7. Every table, enum and function below cites the ruling it carries.
--
-- Conventions (Data Architecture Section 5):
--   * id uuid primary key default gen_random_uuid(), created_at, updated_at on every table
--   * bilingual text = jsonb {"ar": …, "en": …}, at least one key (item 22; 14.2)
--   * money numeric(12,2); registry dates `date`; system moments timestamptz (UTC)
--   * registry identifiers text; hashes bytea; free text `text`, never varchar(n)
--   * vector columns and HNSW indexes are in 0002_pgvector.sql (needs the pgvector extension)
--
-- Access model (Section 6): access to a record is computed, never stored. The view
-- core.v_record_access is the one source; row-level security on every account-facing
-- table reads current_setting('meesam.account_id') through it. Application roles:
--   meesam_app       RLS-bound; the web app sets the account context per transaction
--   meesam_worker    pipelines, bypasses RLS, no account context
--   meesam_staff     Watch Operations Console + technical/payment support
--   meesam_admin     Meesam System Admin
--   meesam_readonly  reporting
-- All five are NOLOGIN group roles; the connecting user runs `SET LOCAL ROLE`.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Extensions, schemas, roles
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS registry;
CREATE SCHEMA IF NOT EXISTS watch;
CREATE SCHEMA IF NOT EXISTS prospect;
CREATE SCHEMA IF NOT EXISTS platform;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meesam_app') THEN
    CREATE ROLE meesam_app NOLOGIN NOBYPASSRLS NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meesam_worker') THEN
    CREATE ROLE meesam_worker NOLOGIN BYPASSRLS NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meesam_staff') THEN
    CREATE ROLE meesam_staff NOLOGIN BYPASSRLS NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meesam_admin') THEN
    CREATE ROLE meesam_admin NOLOGIN BYPASSRLS NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'meesam_readonly') THEN
    CREATE ROLE meesam_readonly NOLOGIN BYPASSRLS NOINHERIT;
  END IF;
END $$;

-- The migration runner's user (the Railway credential) may assume every role.
DO $$
BEGIN
  EXECUTE format('GRANT meesam_app, meesam_worker, meesam_staff, meesam_admin, meesam_readonly TO %I', current_user);
END $$;

-- -----------------------------------------------------------------------------
-- 1. Platform primitives: session context, timestamps, bilingual check, language
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.current_account_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('meesam.account_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION platform.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('meesam.user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION platform.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Bilingual text: an object with at least one non-empty string value (item 22; 14.2).
CREATE OR REPLACE FUNCTION platform.is_i18n_text(v jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL
     AND jsonb_typeof(v) = 'object'
     AND EXISTS (SELECT 1 FROM jsonb_each_text(v) e WHERE length(trim(e.value)) > 0)
$$;

-- Languages are data (14.2): code, script, direction, normaliser. UI locale list reads this.
CREATE TABLE platform.language (
  code        text PRIMARY KEY,
  script      text NOT NULL,                  -- arabic | latin | …
  direction   text NOT NULL CHECK (direction IN ('rtl','ltr')),
  normaliser  text NOT NULL,                  -- name used by watch.fn_normalise_mark
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO platform.language (code, script, direction, normaliser) VALUES
  ('ar', 'arabic', 'rtl', 'arabic'),
  ('en', 'latin',  'ltr', 'latin');

-- -----------------------------------------------------------------------------
-- 2. Enumerations
-- -----------------------------------------------------------------------------
CREATE TYPE core.account_kind AS ENUM ('owner_individual', 'owner_company', 'agency_office');
CREATE TYPE core.verification_method AS ENUM ('staff', 'ai');
CREATE TYPE core.user_role AS ENUM ('company_admin', 'tm_manager', 'agency_admin', 'agent', 'viewer');
CREATE TYPE core.user_status AS ENUM ('invited', 'active', 'suspended', 'removed');
CREATE TYPE core.appointment_status AS ENUM ('requested', 'accepted', 'declined', 'ended');
CREATE TYPE core.party_side AS ENUM ('owner', 'agency');
CREATE TYPE core.instruction_status AS ENUM ('requested', 'active', 'ended', 'declined');
CREATE TYPE core.quote_status AS ENUM ('draft', 'sent', 'selected', 'declined');
CREATE TYPE core.mark_type AS ENUM ('word', 'device', 'combined');

-- Nine stages in exactly the ruled order (item 42). Terminal outcomes stay inside a stage.
CREATE TYPE core.stage AS ENUM (
  'pre_filing',
  'filing_examination',
  'acceptance_publication_opposition',
  'appeals',
  'registration',
  'post_registration_recordals',
  'renewal_grace_expiry',
  'challenges',
  'enforcement'
);
CREATE TYPE core.entry_mode AS ENUM ('new_filing', 'existing', 'bulk_import', 'pass');
CREATE TYPE core.paid_state AS ENUM ('free_new_pending', 'free_loaded', 'read_only_unpaid', 'paid');   -- item 45
CREATE TYPE core.poa_state AS ENUM ('present', 'missing', 'expired');
CREATE TYPE core.scope_kind AS ENUM ('filed', 'watch_only');
CREATE TYPE core.event_type AS ENUM (
  'filed', 'formal_ok', 'office_action', 'response_filed', 'accepted', 'published', 'opposed',
  'appealed', 'registered', 'declaration_of_use', 'recordal', 'renewal_window', 'renewed',
  'expired', 'challenged', 'enforcement', 'cancelled', 'refused', 'withdrawn'
);
CREATE TYPE core.event_source AS ENUM ('manual', 'ai_extract', 'registry_feed', 'bulk_import', 'suggested');
-- Timer taxonomy (item 44): statutory | watch | reminder; registry_service is never materialised.
CREATE TYPE core.timer_family AS ENUM ('statutory', 'watch', 'reminder');
CREATE TYPE core.timer_state AS ENUM ('open', 'met', 'missed', 'cancelled');
CREATE TYPE core.timer_source AS ENUM ('profile', 'user_entered', 'alert');
CREATE TYPE core.extraction_status AS ENUM ('pending', 'extracted', 'accepted', 'rejected');
CREATE TYPE core.payment_case AS ENUM ('registration', 'early_watch', 'existing_watch', 'extra_registry', 'watch_only', 'class_add');

CREATE TYPE watch.stream AS ENUM ('national_bulletin', 'madrid_designations', 'wipo_gazette', 'uspto_tmog', 'other');
CREATE TYPE watch.source_format AS ENUM ('pdf', 'xml', 'json', 'html', 'api');
CREATE TYPE watch.fetch_status AS ENUM ('fetched', 'failed', 'retried', 'parsed', 'verified');
CREATE TYPE watch.fetch_outcome AS ENUM ('fetched', 'not_yet_published', 'failed', 'recovered');
CREATE TYPE watch.frequency AS ENUM ('weekly', 'fortnightly', 'monthly', 'irregular');
CREATE TYPE watch.verify_state AS ENUM ('ai_extracted', 'human_verified', 'waived');
CREATE TYPE watch.risk_band AS ENUM ('high', 'medium', 'low');
CREATE TYPE watch.alert_status AS ENUM ('new', 'reviewing', 'dismissed', 'relevant', 'actioned');
CREATE TYPE watch.feedback_verdict AS ENUM ('relevant', 'not_relevant', 'already_known');
CREATE TYPE watch.threshold_scope AS ENUM ('global', 'registry', 'account');
CREATE TYPE watch.pair_label AS ENUM ('similar', 'not_similar');
CREATE TYPE watch.pair_source AS ENUM ('alert_feedback', 'verifier', 'opposition_outcome', 'golden');

CREATE TYPE prospect.party_kind AS ENUM ('owner', 'agent');
CREATE TYPE prospect.outreach_state AS ENUM ('none', 'eligible', 'contacted', 'converted', 'excluded');
CREATE TYPE prospect.bulletin_type AS ENUM ('published', 'registered', 'renewed', 'madrid_designation', 'recordal');

CREATE TYPE platform.notification_channel AS ENUM ('in_app', 'email');
CREATE TYPE platform.notification_status AS ENUM ('queued', 'sent', 'read', 'failed');
CREATE TYPE platform.job_status AS ENUM ('queued', 'running', 'done', 'failed', 'dead');
CREATE TYPE platform.import_status AS ENUM ('staged', 'validated', 'committed', 'cancelled');

-- -----------------------------------------------------------------------------
-- 3. Schema registry — offices, rules, classification (items 17, 22, 25–28, 42)
-- -----------------------------------------------------------------------------
CREATE TABLE registry.registry (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{2}$'),   -- WIPO ST.3 (August 2026 revision)
  name        jsonb NOT NULL CHECK (platform.is_i18n_text(name)),
  country     char(2) NULL,                                       -- WIPO/Madrid has no country
  supported   boolean NOT NULL DEFAULT false,                     -- live for accounts
  launch_wave smallint NULL,                                      -- 1 = launch, 2 = second wave
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- rules jsonb shape (documented in packages/db/src/registry-profile.ts and docs/README.md):
-- {
--   "calendar": {"timezone": "Asia/Dubai", "weekend": [5,6], "holidays": ["2026-12-02"]},
--   "term": {"years": 10, "from": "filing_date"},
--   "timers": {
--     "<timer_type>": {"start_event": "<event_type>", "days": 30 | "months": 12 | "months_before_expiry": 12,
--                      "verified": true, "extension": null, "consequence": {"ar": "...", "en": "..."}}
--   },
--   "reminders": {"renewal_window": [6, 3, 1]},            -- months before expiry (Ruled 6 Nov)
--   "status_map": {"<event_type>": {"stage": "<core.stage>", "terminal": false, "label": {"ar": "...", "en": "..."}}},
--   "human_review_waived": false,
--   "foreign_applicant_route": {"ar": "...", "en": "..."},
--   "fee_basis": "per_class" | "per_mark",
--   "publication_streams": ["national_bulletin", "madrid_designations"]
-- }
-- A clock without a verified value produces no timer and no day count (item 42 rule ii; item 44).
CREATE TABLE registry.registry_profile (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registry_id    uuid NOT NULL REFERENCES registry.registry(id),
  version        integer NOT NULL,
  effective_from date NOT NULL,
  verified       boolean NOT NULL DEFAULT false,                 -- all clocks verified for launch (12 Nov 2026)
  rules          jsonb NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (registry_id, version),
  CHECK (rules ? 'calendar' AND rules -> 'calendar' ? 'timezone' AND rules ? 'timers')
);
CREATE INDEX ON registry.registry_profile (registry_id, effective_from DESC);

CREATE TABLE registry.nice_class (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  number     smallint NOT NULL UNIQUE CHECK (number BETWEEN 1 AND 45),
  heading    jsonb NOT NULL CHECK (platform.is_i18n_text(heading)),
  edition    text NOT NULL DEFAULT 'NCL(13-2026)',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE registry.nice_term (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  class_id     uuid NOT NULL REFERENCES registry.nice_class(id),
  term         jsonb NOT NULL CHECK (platform.is_i18n_text(term)),
  basic_number text NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON registry.nice_term (class_id);
CREATE INDEX nice_term_en_trgm ON registry.nice_term USING gin ((term ->> 'en') gin_trgm_ops);
CREATE INDEX nice_term_ar_trgm ON registry.nice_term USING gin ((term ->> 'ar') gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- 4. Schema core — identity and parties (items 2–3, 5–6, 9, 30–31, 38–39)
-- -----------------------------------------------------------------------------
CREATE TABLE core.account (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                core.account_kind NOT NULL,
  name                jsonb NOT NULL CHECK (platform.is_i18n_text(name)),
  country             char(2) NOT NULL,
  verified_at         timestamptz NULL,
  verification_method core.verification_method NULL,
  directory_listed    boolean NOT NULL DEFAULT false,
  licence_no          text NULL,
  contact             jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  -- directory_listed only when verified and an agency office (Ruled, 6 Nov)
  CHECK (NOT directory_listed OR (verified_at IS NOT NULL AND kind = 'agency_office')),
  CHECK (verified_at IS NULL OR verification_method IS NOT NULL)
);
CREATE INDEX ON core.account (kind) WHERE directory_listed;

CREATE TABLE core.app_user (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id    uuid NOT NULL REFERENCES core.account(id),
  email         citext NOT NULL UNIQUE,            -- platform-wide: no user in two office accounts (item 38)
  name          text NOT NULL,
  role          core.user_role NOT NULL,
  locale        text NOT NULL DEFAULT 'en' REFERENCES platform.language(code),
  status        core.user_status NOT NULL DEFAULT 'invited',
  password_hash text NULL,
  last_login_at timestamptz NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.app_user (account_id);

-- Role must match the account kind (trigger, Section 11).
CREATE OR REPLACE FUNCTION core.trg_user_role_matches_account() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE k core.account_kind;
BEGIN
  SELECT kind INTO k FROM core.account WHERE id = NEW.account_id;
  IF k = 'agency_office' AND NEW.role NOT IN ('agency_admin', 'agent', 'viewer') THEN
    RAISE EXCEPTION 'role % is not an agency role', NEW.role USING ERRCODE = 'check_violation';
  END IF;
  IF k IN ('owner_individual', 'owner_company') AND NEW.role NOT IN ('company_admin', 'tm_manager') THEN
    RAISE EXCEPTION 'role % is not an owner role', NEW.role USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER user_role_matches_account BEFORE INSERT OR UPDATE OF role, account_id ON core.app_user
  FOR EACH ROW EXECUTE FUNCTION core.trg_user_role_matches_account();

CREATE TABLE core.appointment (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id  uuid NOT NULL REFERENCES core.account(id),
  agency_account_id uuid NOT NULL REFERENCES core.account(id),
  status            core.appointment_status NOT NULL DEFAULT 'requested',
  requested_by      core.party_side NOT NULL,
  requested_at      timestamptz NOT NULL DEFAULT now(),
  accepted_at       timestamptz NULL,
  ended_at          timestamptz NULL,
  ended_by          core.party_side NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (owner_account_id <> agency_account_id),
  CHECK (status <> 'ended' OR (ended_at IS NOT NULL AND ended_by IS NOT NULL))
);
-- One open appointment per owner–agency pair (Inferred)
CREATE UNIQUE INDEX appointment_one_open ON core.appointment (owner_account_id, agency_account_id)
  WHERE status IN ('requested', 'accepted');
CREATE INDEX ON core.appointment (agency_account_id, status);

CREATE TABLE core.mark_family (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id uuid NOT NULL REFERENCES core.account(id),
  name             jsonb NOT NULL CHECK (platform.is_i18n_text(name)),
  mark_type        core.mark_type NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.mark_family (owner_account_id);

CREATE TABLE core.record (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mark_family_id             uuid NOT NULL REFERENCES core.mark_family(id),
  registry_id                uuid NOT NULL REFERENCES registry.registry(id),
  application_no             text NULL,
  registration_no            text NULL,
  filing_date                date NULL,
  registration_date          date NULL,
  expiry_date                date NULL,
  mark_text                  jsonb NULL CHECK (mark_text IS NULL OR platform.is_i18n_text(mark_text)),
  mark_text_norm             jsonb NULL,
  phonetic_key               text NULL,
  mark_image_doc_id          uuid NULL,                       -- fk added after core.document exists
  stage                      core.stage NOT NULL DEFAULT 'pre_filing',
  status_label               jsonb NULL,
  terminal                   boolean NOT NULL DEFAULT false,
  entry_mode                 core.entry_mode NOT NULL,
  paid_state                 core.paid_state NOT NULL,
  watch_active_from          timestamptz NULL,
  agent_of_record_account_id uuid NULL REFERENCES core.account(id),
  poa_state                  core.poa_state NOT NULL DEFAULT 'missing',
  madrid                     jsonb NULL,                      -- {role, international_registration_no, designations[], central_renewal_date, dependency_until}
  warnings                   jsonb NOT NULL DEFAULT '[]'::jsonb,   -- advisory checks kept on the record (10 Nov 2026)
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now()
);
-- One Meesam record per application per registry (case 1; item 20)
CREATE UNIQUE INDEX record_one_per_application ON core.record (registry_id, application_no) WHERE application_no IS NOT NULL;
CREATE UNIQUE INDEX record_one_per_family_registry ON core.record (mark_family_id, registry_id)
  WHERE madrid IS NULL;   -- a Madrid designation is its own row under its country's registry
CREATE INDEX ON core.record (mark_family_id);
CREATE INDEX ON core.record (registry_id);
CREATE INDEX ON core.record (expiry_date);
CREATE INDEX ON core.record (poa_state) WHERE poa_state <> 'present';
CREATE INDEX ON core.record (agent_of_record_account_id);
CREATE INDEX record_mark_en_trgm ON core.record USING gin ((mark_text_norm ->> 'en') gin_trgm_ops);
CREATE INDEX record_mark_ar_trgm ON core.record USING gin ((mark_text_norm ->> 'ar') gin_trgm_ops);

CREATE TABLE core.appointment_record (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  appointment_id uuid NOT NULL REFERENCES core.appointment(id),
  record_id      uuid NOT NULL REFERENCES core.record(id),
  added_at       timestamptz NOT NULL DEFAULT now(),
  removed_at     timestamptz NULL,                             -- owner revokes one record (item 22)
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX appointment_record_live ON core.appointment_record (appointment_id, record_id) WHERE removed_at IS NULL;
CREATE INDEX ON core.appointment_record (record_id);

CREATE TABLE core.document_type (
  code       text PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),     -- item 14.16: 14 three-letter codes
  name       jsonb NOT NULL CHECK (platform.is_i18n_text(name)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO core.document_type (code, name) VALUES
  ('APP', '{"en": "Application as filed", "ar": "طلب التسجيل كما قُدِّم"}'),
  ('OAC', '{"en": "Office action", "ar": "إخطار من المكتب"}'),
  ('RSP', '{"en": "Response to office action", "ar": "الرد على إخطار المكتب"}'),
  ('PUB', '{"en": "Publication copy", "ar": "نسخة النشر"}'),
  ('OPP', '{"en": "Opposition", "ar": "اعتراض"}'),
  ('ORC', '{"en": "Registration certificate", "ar": "شهادة التسجيل"}'),
  ('REN', '{"en": "Renewal certificate", "ar": "شهادة التجديد"}'),
  ('DOU', '{"en": "Declaration of use", "ar": "إقرار الاستخدام"}'),
  ('ASG', '{"en": "Assignment", "ar": "تنازل"}'),
  ('LIC', '{"en": "Licence", "ar": "ترخيص"}'),
  ('CNA', '{"en": "Change of name or address", "ar": "تغيير الاسم أو العنوان"}'),
  ('POA', '{"en": "Power of attorney", "ar": "وكالة"}'),
  ('LGR', '{"en": "Legal request", "ar": "طلب قانوني"}'),
  ('OTH', '{"en": "Other", "ar": "أخرى"}');

CREATE TABLE core.document (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id           uuid NOT NULL REFERENCES core.record(id),
  doc_type            text NOT NULL REFERENCES core.document_type(code),
  serial_no           text NULL,
  object_key          text NOT NULL,                         -- vault: regno_serial_DDMMYY_TYPE.ext (item 43)
  file_name           text NOT NULL,
  content_type        text NULL,
  size_bytes          bigint NULL,
  sha256              bytea NOT NULL,
  extracted           jsonb NULL,
  extraction_status   core.extraction_status NOT NULL DEFAULT 'pending',
  valid_until         date NULL,                             -- POA validity drives record.poa_state
  uploaded_by_user_id uuid NULL REFERENCES core.app_user(id),
  uploaded_by_account_id uuid NULL REFERENCES core.account(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.document (record_id, doc_type);
CREATE UNIQUE INDEX document_object_key ON core.document (object_key);
ALTER TABLE core.record ADD CONSTRAINT record_mark_image_fk FOREIGN KEY (mark_image_doc_id) REFERENCES core.document(id);

CREATE TABLE core.cross_border_instruction (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_account_id      uuid NOT NULL REFERENCES core.account(id),
  to_account_id        uuid NOT NULL REFERENCES core.account(id),
  record_id            uuid NOT NULL REFERENCES core.record(id),
  status               core.instruction_status NOT NULL DEFAULT 'requested',
  legal_request_doc_id uuid NULL REFERENCES core.document(id),
  poa_doc_id           uuid NULL REFERENCES core.document(id),
  ended_at             timestamptz NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CHECK (from_account_id <> to_account_id)
);
CREATE INDEX ON core.cross_border_instruction (record_id, status);
CREATE INDEX ON core.cross_border_instruction (to_account_id, status);

CREATE TABLE core.owner_pass (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id              uuid NOT NULL REFERENCES core.record(id),
  issued_by_account_id   uuid NOT NULL REFERENCES core.account(id),
  token_hash             bytea NOT NULL UNIQUE,
  expires_at             timestamptz NOT NULL DEFAULT now() + interval '30 days',
  redeemed_at            timestamptz NULL,
  redeemed_by_account_id uuid NULL REFERENCES core.account(id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.owner_pass (record_id);

CREATE TABLE core.quote_request (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_account_id uuid NOT NULL REFERENCES core.account(id),
  record_id        uuid NULL REFERENCES core.record(id),
  brief            jsonb NOT NULL DEFAULT '{}'::jsonb,
  sent_to_count    integer NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.quote_request (owner_account_id);

-- Inferred: the agencies a quote request was sent to (needed to route the request and its RLS).
CREATE TABLE core.quote_request_recipient (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_request_id  uuid NOT NULL REFERENCES core.quote_request(id),
  agency_account_id uuid NOT NULL REFERENCES core.account(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (quote_request_id, agency_account_id)
);
CREATE INDEX ON core.quote_request_recipient (agency_account_id);

CREATE OR REPLACE FUNCTION core.trg_quote_request_count() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE core.quote_request q SET sent_to_count = (SELECT count(*) FROM core.quote_request_recipient r WHERE r.quote_request_id = q.id)
   WHERE q.id = COALESCE(NEW.quote_request_id, OLD.quote_request_id);
  RETURN NULL;
END $$;
CREATE TRIGGER quote_request_count AFTER INSERT OR DELETE ON core.quote_request_recipient
  FOR EACH ROW EXECUTE FUNCTION core.trg_quote_request_count();

CREATE TABLE core.quote (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_request_id  uuid NOT NULL REFERENCES core.quote_request(id),
  agency_account_id uuid NOT NULL REFERENCES core.account(id),
  amount            numeric(12,2) NOT NULL CHECK (amount >= 0),
  currency          char(3) NOT NULL DEFAULT 'AED',
  status            core.quote_status NOT NULL DEFAULT 'draft',
  note              jsonb NULL,
  sent_by_user_id   uuid NULL REFERENCES core.app_user(id),
  sent_at           timestamptz NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (quote_request_id, agency_account_id)
);

-- Only agency_admin may move draft → sent (Ruled, 6 Nov)
CREATE OR REPLACE FUNCTION core.trg_quote_send_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r core.user_role;
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'sent' THEN
    SELECT role INTO r FROM core.app_user WHERE id = COALESCE(NEW.sent_by_user_id, platform.current_user_id());
    IF r IS DISTINCT FROM 'agency_admin' THEN
      RAISE EXCEPTION 'only an agency administrator may send a quote' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.sent_at := now();
    NEW.sent_by_user_id := COALESCE(NEW.sent_by_user_id, platform.current_user_id());
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER quote_send_guard BEFORE UPDATE OF status ON core.quote
  FOR EACH ROW EXECUTE FUNCTION core.trg_quote_send_guard();

CREATE TABLE core.message_thread (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id         uuid NOT NULL REFERENCES core.record(id),
  owner_account_id  uuid NOT NULL REFERENCES core.account(id),
  agency_account_id uuid NOT NULL REFERENCES core.account(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (record_id, owner_account_id, agency_account_id)     -- one thread per record per pair (item 39)
);

CREATE TABLE core.message (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id      uuid NOT NULL REFERENCES core.message_thread(id),
  author_user_id uuid NOT NULL REFERENCES core.app_user(id),
  author_account_id uuid NOT NULL REFERENCES core.account(id),
  body           text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.message (thread_id, created_at);

-- -----------------------------------------------------------------------------
-- 5. Schema core — marks: classes, scopes, events, timers, edits (items 17, 37, 40, 42–45)
-- -----------------------------------------------------------------------------
CREATE TABLE core.price_list (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version        integer NOT NULL UNIQUE,
  effective_from date NOT NULL,
  rules          jsonb NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.payment (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id        uuid NOT NULL REFERENCES core.record(id),
  payer_account_id uuid NOT NULL REFERENCES core.account(id),
  "case"           core.payment_case NOT NULL,
  years_remaining  smallint NULL,
  amount           numeric(12,2) NOT NULL CHECK (amount >= 0),
  vat              numeric(12,2) NOT NULL DEFAULT 0 CHECK (vat >= 0),
  currency         char(3) NOT NULL DEFAULT 'AED',
  issuer           text NOT NULL,                              -- invoicing entity per payment (14.19); from INVOICE_ISSUER
  provider_ref     text NULL,                                  -- gateway token only; no card data (Section 12)
  paid_at          timestamptz NOT NULL DEFAULT now(),
  refundable       boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.payment (record_id);
CREATE INDEX ON core.payment (payer_account_id, paid_at DESC);
-- One record paid once for its registration however many accounts hold it (case 1)
CREATE UNIQUE INDEX payment_one_registration ON core.payment (record_id) WHERE "case" IN ('registration', 'early_watch', 'existing_watch');

CREATE TABLE core.record_class (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id      uuid NOT NULL REFERENCES core.record(id),
  nice_class_id  uuid NOT NULL REFERENCES registry.nice_class(id),
  added_at       timestamptz NOT NULL DEFAULT now(),
  terms          jsonb NULL,
  fee_payment_id uuid NULL REFERENCES core.payment(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (record_id, nice_class_id)
);

CREATE TABLE core.record_registry_scope (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id   uuid NOT NULL REFERENCES core.record(id),
  registry_id uuid NOT NULL REFERENCES registry.registry(id),
  kind        core.scope_kind NOT NULL,
  added_at    timestamptz NOT NULL DEFAULT now(),
  payment_id  uuid NULL REFERENCES core.payment(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (record_id, registry_id)
);

CREATE TABLE core.record_event (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id            uuid NOT NULL REFERENCES core.record(id),
  event_type           core.event_type NOT NULL,
  event_date           date NOT NULL,
  source               core.event_source NOT NULL DEFAULT 'manual',
  registry_status      text NULL,                              -- the registry's own wording, verbatim (14.7)
  detail               jsonb NOT NULL DEFAULT '{}'::jsonb,
  publication_issue_id uuid NULL,                              -- watch.publication_issue (fk added below)
  confirmed_at         timestamptz NULL,                       -- suggested events move the stage only on confirmation (item 44)
  confirmed_by_user_id uuid NULL REFERENCES core.app_user(id),
  verified_by_user_id  uuid NULL REFERENCES core.app_user(id),
  created_by_account_id uuid NULL REFERENCES core.account(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.record_event (record_id, event_date DESC, created_at DESC);
CREATE INDEX ON core.record_event (record_id) WHERE source = 'suggested' AND confirmed_at IS NULL;

CREATE TABLE core.timer (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id           uuid NOT NULL REFERENCES core.record(id),
  event_id            uuid NULL REFERENCES core.record_event(id),
  family              core.timer_family NOT NULL,
  timer_type          text NOT NULL,                           -- oppose, counter, pay_registration, renewal_window, expiry, grace, declaration_of_use, reminder_6m, …
  due_date            date NULL,                               -- NULL while the user has yet to enter it
  due_at              timestamptz NULL,                        -- 23:59 registry-local on due_date (item 44)
  state               core.timer_state NOT NULL DEFAULT 'open',
  source              core.timer_source NOT NULL,
  awaiting_user_entry boolean NOT NULL DEFAULT false,          -- unverified clock: no default supplied
  alert_id            uuid NULL,                               -- watch.alert for family = watch (fk added below)
  met_at              timestamptz NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (awaiting_user_entry OR due_date IS NOT NULL)
);
CREATE INDEX ON core.timer (record_id, state, due_date);
CREATE INDEX ON core.timer (due_at) WHERE state = 'open';
CREATE INDEX ON core.timer (event_id);

CREATE TABLE core.record_edit (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id           uuid NOT NULL REFERENCES core.record(id),
  user_id             uuid NULL REFERENCES core.app_user(id),
  account_id          uuid NULL REFERENCES core.account(id),
  table_name          text NOT NULL,
  changed             jsonb NOT NULL,                          -- {"before": {...}, "after": {...}}
  notified_account_id uuid NULL REFERENCES core.account(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON core.record_edit (record_id, created_at DESC);

-- -----------------------------------------------------------------------------
-- 6. Schema platform — audit, notification, telemetry, feedback, import, job queue
-- -----------------------------------------------------------------------------
-- Partition helpers: monthly range partitions created ahead by the nightly job.
CREATE OR REPLACE FUNCTION platform.ensure_month_partitions(p_schema text, p_table text, p_months_ahead integer DEFAULT 3)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE m date := date_trunc('month', current_date)::date; i integer; part text;
BEGIN
  FOR i IN -1..p_months_ahead LOOP
    part := format('%s_%s', p_table, to_char(m + (i || ' months')::interval, 'YYYY_MM'));
    IF to_regclass(format('%I.%I', p_schema, part)) IS NULL THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
        p_schema, part, p_schema, p_table,
        (m + (i || ' months')::interval)::date, (m + ((i + 1) || ' months')::interval)::date);
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION platform.ensure_year_partitions(p_schema text, p_table text, p_years_ahead integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE y integer := extract(year FROM current_date)::integer; i integer; part text;
BEGIN
  FOR i IN -1..p_years_ahead LOOP
    part := format('%s_%s', p_table, y + i);
    IF to_regclass(format('%I.%I', p_schema, part)) IS NULL THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
        p_schema, part, p_schema, p_table, make_date(y + i, 1, 1), make_date(y + i + 1, 1, 1));
    END IF;
  END LOOP;
END $$;

-- Audit: who changed what, when, from which account (item 39). Kept forever (14.10).
CREATE TABLE platform.audit_event (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  account_id  uuid NULL,
  user_id     uuid NULL,
  db_role     text NOT NULL DEFAULT current_user,
  schema_name text NOT NULL,
  table_name  text NOT NULL,
  row_id      uuid NULL,
  record_id   uuid NULL,
  action      text NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  before      jsonb NULL,
  after       jsonb NULL,
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE INDEX ON platform.audit_event (account_id, occurred_at DESC);
CREATE INDEX ON platform.audit_event (record_id, occurred_at DESC);
SELECT platform.ensure_month_partitions('platform', 'audit_event', 12);

CREATE TABLE platform.notification (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid NOT NULL REFERENCES core.account(id),
  user_id      uuid NULL REFERENCES core.app_user(id),           -- NULL = every user of the account
  channel      platform.notification_channel NOT NULL,
  kind         text NOT NULL,                                    -- record_edited, appointment_requested, alert_new, timer_due, …
  record_id    uuid NULL REFERENCES core.record(id),
  payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
  status       platform.notification_status NOT NULL DEFAULT 'queued',
  sent_at      timestamptz NULL,
  read_at      timestamptz NULL,
  dedupe_key   text NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON platform.notification (account_id, status, created_at DESC);
CREATE INDEX ON platform.notification (user_id, read_at) WHERE channel = 'in_app';
CREATE UNIQUE INDEX notification_dedupe ON platform.notification (dedupe_key) WHERE dedupe_key IS NOT NULL;

-- Telemetry raw rows 24 months, monthly partitions, then aggregated (14.10).
CREATE TABLE platform.telemetry_event (
  id          uuid NOT NULL DEFAULT gen_random_uuid(),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  account_id  uuid NULL,
  user_id     uuid NULL,
  event       text NOT NULL,
  properties  jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (id, occurred_at)
) PARTITION BY RANGE (occurred_at);
CREATE INDEX ON platform.telemetry_event (account_id, occurred_at);
SELECT platform.ensure_month_partitions('platform', 'telemetry_event', 3);

CREATE TABLE platform.telemetry_monthly (
  month       date NOT NULL,
  account_id  uuid NULL,
  event       text NOT NULL,
  count       bigint NOT NULL,
  PRIMARY KEY (month, account_id, event)
);

CREATE TABLE platform.feedback (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NULL REFERENCES core.account(id),
  user_id    uuid NULL REFERENCES core.app_user(id),
  page       text NULL,
  body       text NOT NULL,
  locale     text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE platform.import_batch (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL REFERENCES core.account(id),
  user_id         uuid NULL REFERENCES core.app_user(id),
  file_object_key text NULL,
  status          platform.import_status NOT NULL DEFAULT 'staged',
  summary         jsonb NOT NULL DEFAULT '{}'::jsonb,            -- rows loaded, warnings, timers created (item 44)
  committed_at    timestamptz NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON platform.import_batch (account_id, created_at DESC);

CREATE TABLE platform.import_row (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id   uuid NOT NULL REFERENCES platform.import_batch(id),
  row_no     integer NOT NULL,
  raw        jsonb NOT NULL,                                     -- text as staged, no typing
  warnings   jsonb NOT NULL DEFAULT '[]'::jsonb,                 -- advisory (10 Nov 2026)
  errors     jsonb NOT NULL DEFAULT '[]'::jsonb,                 -- only unreadable rows stay in the batch
  record_id  uuid NULL REFERENCES core.record(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (batch_id, row_no)
);

-- Job queue: PostgreSQL table, SELECT … FOR UPDATE SKIP LOCKED (14.11, Ruled).
CREATE TABLE platform.job (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         text NOT NULL,
  payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
  status       platform.job_status NOT NULL DEFAULT 'queued',
  run_at       timestamptz NOT NULL DEFAULT now(),
  priority     smallint NOT NULL DEFAULT 100,
  attempts     integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 5,
  locked_at    timestamptz NULL,
  locked_by    text NULL,
  finished_at  timestamptz NULL,
  last_error   text NULL,
  dedupe_key   text NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX job_ready ON platform.job (priority, run_at) WHERE status = 'queued';
CREATE UNIQUE INDEX job_dedupe ON platform.job (dedupe_key) WHERE dedupe_key IS NOT NULL AND status IN ('queued', 'running');

CREATE OR REPLACE FUNCTION platform.enqueue_job(p_kind text, p_payload jsonb DEFAULT '{}'::jsonb, p_run_at timestamptz DEFAULT now(),
                                                p_dedupe_key text DEFAULT NULL, p_priority smallint DEFAULT 100)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO platform.job (kind, payload, run_at, dedupe_key, priority)
  VALUES (p_kind, p_payload, p_run_at, p_dedupe_key, p_priority)
  ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL AND status IN ('queued', 'running') DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION platform.claim_jobs(p_worker text, p_limit integer DEFAULT 5, p_kinds text[] DEFAULT NULL)
RETURNS SETOF platform.job LANGUAGE sql AS $$
  WITH picked AS (
    SELECT id FROM platform.job
     WHERE status = 'queued' AND run_at <= now() AND (p_kinds IS NULL OR kind = ANY (p_kinds))
     ORDER BY priority, run_at
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  )
  UPDATE platform.job j
     SET status = 'running', locked_at = now(), locked_by = p_worker, attempts = attempts + 1, updated_at = now()
    FROM picked WHERE j.id = picked.id
  RETURNING j.*
$$;

CREATE OR REPLACE FUNCTION platform.complete_job(p_id uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE platform.job SET status = 'done', finished_at = now(), locked_at = NULL, locked_by = NULL, updated_at = now() WHERE id = p_id
$$;

-- Failure: exponential back-off (1, 2, 4, 8 … minutes, capped at 6 h); dead after max_attempts.
CREATE OR REPLACE FUNCTION platform.fail_job(p_id uuid, p_error text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE j platform.job;
BEGIN
  SELECT * INTO j FROM platform.job WHERE id = p_id FOR UPDATE;
  IF j.attempts >= j.max_attempts THEN
    UPDATE platform.job SET status = 'dead', last_error = p_error, finished_at = now(), locked_at = NULL, locked_by = NULL, updated_at = now() WHERE id = p_id;
  ELSE
    UPDATE platform.job SET status = 'queued', last_error = p_error, locked_at = NULL, locked_by = NULL, updated_at = now(),
           run_at = now() + least(interval '6 hours', (interval '1 minute' * power(2, j.attempts - 1))) WHERE id = p_id;
  END IF;
END $$;

-- Jobs left "running" by a crashed worker are requeued by the nightly housekeeping job.
CREATE OR REPLACE FUNCTION platform.requeue_stale_jobs(p_older_than interval DEFAULT interval '30 minutes') RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE platform.job SET status = 'queued', locked_at = NULL, locked_by = NULL, updated_at = now()
   WHERE status = 'running' AND locked_at < now() - p_older_than;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- -----------------------------------------------------------------------------
-- 7. Schema watch (Section 8; MSM-PRD-02 v1.1)
-- -----------------------------------------------------------------------------
CREATE TABLE watch.publication_source (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registry_id uuid NOT NULL REFERENCES registry.registry(id),
  stream      watch.stream NOT NULL,
  fetch_spec  jsonb NOT NULL DEFAULT '{}'::jsonb,                -- URL pattern, auth, parser name
  format      watch.source_format NOT NULL,
  cadence     text NOT NULL DEFAULT 'weekly',
  active      boolean NOT NULL DEFAULT false,                    -- WIPO Gazette stays inactive until agreement (12 Nov 2026)
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (registry_id, stream)
);

CREATE TABLE watch.publication_schedule (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id     uuid NOT NULL REFERENCES watch.publication_source(id),
  frequency     watch.frequency NOT NULL,
  weekday       smallint NULL CHECK (weekday BETWEEN 0 AND 6),
  local_time    time NULL,
  timezone      text NOT NULL,
  expected_next date NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id)
);

CREATE TABLE watch.publication_issue (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id    uuid NOT NULL REFERENCES watch.publication_source(id),
  issue_no     text NOT NULL,
  published_on date NULL,
  fetched_at   timestamptz NULL,
  object_key   text NULL,
  sha256       bytea NULL UNIQUE,                                 -- a re-fetched issue is never parsed twice
  fetch_status watch.fetch_status NOT NULL DEFAULT 'fetched',
  recovery_log jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, issue_no)
);
ALTER TABLE core.record_event ADD CONSTRAINT record_event_issue_fk FOREIGN KEY (publication_issue_id) REFERENCES watch.publication_issue(id);

CREATE TABLE watch.fetch_run (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id   uuid NOT NULL REFERENCES watch.publication_source(id),
  issue_id    uuid NULL REFERENCES watch.publication_issue(id),
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz NULL,
  outcome     watch.fetch_outcome NULL,
  attempt     integer NOT NULL DEFAULT 1,
  detail      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON watch.fetch_run (source_id, started_at DESC);

-- Partitioned by registry (list) then publication_date (yearly range). Primary key must carry the
-- partition keys, so other tables reference published_mark by id without a foreign key.
CREATE TABLE watch.published_mark (
  id                  uuid NOT NULL DEFAULT gen_random_uuid(),
  issue_id            uuid NOT NULL REFERENCES watch.publication_issue(id),
  registry_id         uuid NOT NULL REFERENCES registry.registry(id),
  publication_date    date NOT NULL,
  application_no      text NULL,
  mark_text           jsonb NULL,
  mark_text_norm      jsonb NULL,
  phonetic_key        text NULL,
  mark_image_key      text NULL,
  phash               bytea NULL,
  classes             smallint[] NOT NULL DEFAULT '{}',
  applicant_name      text NULL,
  applicant_country   char(2) NULL,
  agent_name          text NULL,
  opposition_deadline date NULL,
  extraction          jsonb NOT NULL DEFAULT '{}'::jsonb,        -- page, bounding box, Vienna codes, confidence
  verify_state        watch.verify_state NOT NULL DEFAULT 'ai_extracted',
  verified_by_user_id uuid NULL,
  prospect_owner_id   uuid NULL,
  prospect_agent_id   uuid NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (registry_id, publication_date, id)
) PARTITION BY LIST (registry_id);
CREATE TABLE watch.published_mark_default PARTITION OF watch.published_mark DEFAULT;
CREATE INDEX ON watch.published_mark (issue_id);
CREATE INDEX ON watch.published_mark USING gin (classes);
CREATE INDEX published_mark_en_trgm ON watch.published_mark USING gin ((mark_text_norm ->> 'en') gin_trgm_ops);
CREATE INDEX published_mark_ar_trgm ON watch.published_mark USING gin ((mark_text_norm ->> 'ar') gin_trgm_ops);
CREATE INDEX ON watch.published_mark (verify_state) WHERE verify_state = 'ai_extracted';

-- Per-registry sub-partition (itself ranged by year) created when a registry row is inserted.
CREATE OR REPLACE FUNCTION watch.ensure_published_mark_partitions(p_registry_id uuid, p_years_ahead integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_code text; v_parent text; y integer := extract(year FROM current_date)::integer; i integer; part text;
BEGIN
  SELECT lower(code) INTO v_code FROM registry.registry WHERE id = p_registry_id;
  IF v_code IS NULL THEN RETURN; END IF;
  v_parent := format('published_mark_%s', v_code);
  IF to_regclass(format('watch.%I', v_parent)) IS NULL THEN
    EXECUTE format('CREATE TABLE watch.%I PARTITION OF watch.published_mark FOR VALUES IN (%L) PARTITION BY RANGE (publication_date)', v_parent, p_registry_id);
    EXECUTE format('CREATE TABLE watch.%I PARTITION OF watch.%I DEFAULT', v_parent || '_default', v_parent);
  END IF;
  FOR i IN -1..p_years_ahead LOOP
    part := format('%s_%s', v_parent, y + i);
    IF to_regclass(format('watch.%I', part)) IS NULL THEN
      EXECUTE format('CREATE TABLE watch.%I PARTITION OF watch.%I FOR VALUES FROM (%L) TO (%L)',
        part, v_parent, make_date(y + i, 1, 1), make_date(y + i + 1, 1, 1));
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION registry.trg_registry_partitions() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM watch.ensure_published_mark_partitions(NEW.id);
  RETURN NULL;
END $$;
CREATE TRIGGER registry_partitions AFTER INSERT ON registry.registry FOR EACH ROW EXECUTE FUNCTION registry.trg_registry_partitions();

CREATE TABLE watch.watch_scope (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id      uuid NOT NULL REFERENCES core.record(id),
  account_id     uuid NOT NULL REFERENCES core.account(id),
  registry_id    uuid NOT NULL REFERENCES registry.registry(id),
  classes        smallint[] NULL,                                 -- NULL = all classes
  countries      char(2)[] NULL,                                  -- Madrid (WO) scope: selected designations
  set_by_user_id uuid NULL REFERENCES core.app_user(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (record_id, account_id, registry_id)
);
CREATE INDEX ON watch.watch_scope (registry_id);

CREATE TABLE watch.comparison_run (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id         uuid NULL REFERENCES watch.publication_issue(id),
  import_batch_id  uuid NULL REFERENCES platform.import_batch(id),  -- retrospective run (item 45)
  started_at       timestamptz NOT NULL DEFAULT now(),
  finished_at      timestamptz NULL,
  engine_version   text NOT NULL,
  records_compared integer NOT NULL DEFAULT 0,
  candidates       integer NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (issue_id IS NOT NULL OR import_batch_id IS NOT NULL)
);
CREATE UNIQUE INDEX comparison_run_once ON watch.comparison_run (issue_id, engine_version) WHERE issue_id IS NOT NULL;

-- Partitioned yearly on created_at (Section 11). Referenced by id without a foreign key.
CREATE TABLE watch.candidate (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  run_id            uuid NOT NULL REFERENCES watch.comparison_run(id),
  published_mark_id uuid NOT NULL,
  record_id         uuid NOT NULL REFERENCES core.record(id),
  score_text        numeric(5,4) NULL,
  score_phonetic    numeric(5,4) NULL,
  score_image       numeric(5,4) NULL,
  score_cross_mode  numeric(5,4) NULL,
  score             numeric(5,4) NOT NULL,
  class_overlap     smallint[] NOT NULL DEFAULT '{}',
  explanation       jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at),
  UNIQUE (run_id, published_mark_id, record_id, created_at)
) PARTITION BY RANGE (created_at);
CREATE INDEX ON watch.candidate (record_id);
SELECT platform.ensure_year_partitions('watch', 'candidate', 1);

CREATE TABLE watch.alert (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id        uuid NOT NULL,
  record_id           uuid NOT NULL REFERENCES core.record(id),
  registry_id         uuid NOT NULL REFERENCES registry.registry(id),  -- alerts are per registry, never merged (MSM-PRD-02 13.15)
  account_id          uuid NOT NULL REFERENCES core.account(id),       -- one alert per candidate per account (item 18)
  risk_band           watch.risk_band NOT NULL,
  status              watch.alert_status NOT NULL DEFAULT 'new',
  opposition_deadline date NULL,
  reminded_at         timestamptz[] NOT NULL DEFAULT '{}',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (candidate_id, account_id)
);
CREATE INDEX ON watch.alert (account_id, risk_band, status);
CREATE INDEX ON watch.alert (account_id) WHERE status = 'new';
CREATE INDEX ON watch.alert (record_id);
ALTER TABLE core.timer ADD CONSTRAINT timer_alert_fk FOREIGN KEY (alert_id) REFERENCES watch.alert(id);

CREATE TABLE watch.alert_feedback (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id   uuid NOT NULL REFERENCES watch.alert(id),
  user_id    uuid NOT NULL REFERENCES core.app_user(id),
  verdict    watch.feedback_verdict NOT NULL,
  note       text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON watch.alert_feedback (alert_id);

CREATE TABLE watch.own_filing_suppression (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id         uuid NOT NULL REFERENCES core.record(id),
  published_mark_id uuid NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (record_id, published_mark_id)
);

CREATE TABLE watch.threshold (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope       watch.threshold_scope NOT NULL,
  scope_id    uuid NULL,
  band_high   numeric(5,4) NOT NULL,
  band_medium numeric(5,4) NOT NULL,
  floor       numeric(5,4) NOT NULL DEFAULT 0.5,                  -- below this no candidate is written
  version     integer NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (band_high > band_medium AND band_medium >= floor),
  CHECK ((scope = 'global') = (scope_id IS NULL))
);
CREATE UNIQUE INDEX threshold_scope_version ON watch.threshold (scope, COALESCE(scope_id, '00000000-0000-0000-0000-000000000000'::uuid), version);
-- RULING NEEDED: initial risk-band cut-offs. Engineering starting point only; tuned from alert_feedback (Ruled 6 Nov).
INSERT INTO watch.threshold (scope, band_high, band_medium, floor) VALUES ('global', 0.85, 0.70, 0.55);

CREATE TABLE watch.retro_report (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_batch_id uuid NOT NULL UNIQUE REFERENCES platform.import_batch(id),
  account_id      uuid NOT NULL REFERENCES core.account(id),
  run_id          uuid NULL REFERENCES watch.comparison_run(id),
  summary         jsonb NOT NULL DEFAULT '{}'::jsonb,
  delivered_at    timestamptz NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Labelled pairs collected from day one (14.3 item 3) and the frozen golden set (item 5).
CREATE TABLE watch.training_pair (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id         uuid NULL REFERENCES core.record(id),
  record_image_id   uuid NULL REFERENCES core.document(id),
  published_mark_id uuid NOT NULL,
  label             watch.pair_label NOT NULL,
  source            watch.pair_source NOT NULL,
  labelled_at       timestamptz NOT NULL DEFAULT now(),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE watch.eval_pair (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  left_image_key    text NOT NULL,
  right_image_key   text NOT NULL,
  label             watch.pair_label NOT NULL,
  judged_by         text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- 8. Schema prospect (Section 9) — staff-only, derived from published_mark
-- -----------------------------------------------------------------------------
CREATE TABLE prospect.prospect_party (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind           prospect.party_kind NOT NULL,
  name_raw       text NOT NULL,
  name_norm      text NOT NULL,
  country        char(2) NOT NULL DEFAULT 'XX',
  registry_ids   uuid[] NOT NULL DEFAULT '{}',
  first_seen     date NULL,
  last_seen      date NULL,
  marks_count    integer NOT NULL DEFAULT 0,
  account_id     uuid NULL REFERENCES core.account(id),          -- conversion link only
  contact        jsonb NULL,                                      -- filled by staff from outreach
  outreach_state prospect.outreach_state NOT NULL DEFAULT 'none',
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, name_norm, country)
);
CREATE INDEX prospect_party_norm_trgm ON prospect.prospect_party USING gin (name_norm gin_trgm_ops);

CREATE TABLE prospect.prospect_party_alias (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  party_id        uuid NOT NULL REFERENCES prospect.prospect_party(id),
  name_raw        text NOT NULL,
  source_issue_id uuid NULL REFERENCES watch.publication_issue(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON prospect.prospect_party_alias (party_id);

CREATE TABLE prospect.prospect_mark (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  published_mark_id uuid NOT NULL UNIQUE,
  owner_party_id    uuid NOT NULL REFERENCES prospect.prospect_party(id),
  agent_party_id    uuid NULL REFERENCES prospect.prospect_party(id),
  bulletin_type     prospect.bulletin_type NOT NULL,
  registry_id       uuid NOT NULL REFERENCES registry.registry(id),
  country           char(2) NOT NULL DEFAULT 'XX',
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON prospect.prospect_mark (owner_party_id);
CREATE INDEX ON prospect.prospect_mark (agent_party_id);
CREATE INDEX ON prospect.prospect_mark (registry_id, bulletin_type, country);

CREATE TABLE prospect.prospect_agent_rank (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  registry_id    uuid NOT NULL REFERENCES registry.registry(id),
  issue_id       uuid NOT NULL REFERENCES watch.publication_issue(id),
  agent_party_id uuid NOT NULL REFERENCES prospect.prospect_party(id),
  marks_in_issue integer NOT NULL,
  rank           integer NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (issue_id, agent_party_id)
);

-- -----------------------------------------------------------------------------
-- 9. updated_at triggers on every table with the column
-- -----------------------------------------------------------------------------
DO $$
DECLARE t record;
BEGIN
  FOR t IN
    SELECT c.table_schema, c.table_name
      FROM information_schema.columns c
      JOIN pg_class pc ON pc.relname = c.table_name
      JOIN pg_namespace n ON n.oid = pc.relnamespace AND n.nspname = c.table_schema
     WHERE c.column_name = 'updated_at'
       AND c.table_schema IN ('core', 'registry', 'watch', 'prospect', 'platform')
       AND pc.relkind IN ('r', 'p')
       AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = pc.oid)   -- parents only
  LOOP
    EXECUTE format('CREATE TRIGGER touch_updated_at BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION platform.touch_updated_at()',
                   t.table_schema, t.table_name);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 10. Access view and helpers (Section 6)
-- -----------------------------------------------------------------------------
-- Runs with the owner's privileges (not security_invoker), so RLS below can read it without recursion.
CREATE VIEW core.v_record_access (record_id, account_id, via, can_edit) AS
  -- ownership: all records in the family, forever
  SELECT r.id, f.owner_account_id, 'owner'::text, true
    FROM core.record r JOIN core.mark_family f ON f.id = r.mark_family_id
  UNION ALL
  -- accepted appointment, record in scope and not revoked
  SELECT ar.record_id, a.agency_account_id, 'appointment', true
    FROM core.appointment a
    JOIN core.appointment_record ar ON ar.appointment_id = a.id AND ar.removed_at IS NULL
   WHERE a.status = 'accepted' AND a.ended_at IS NULL
  UNION ALL
  -- cross-border instruction, while active
  -- RULING NEEDED: may the instructed office edit the record, or only read it? Narrowest reading: read only.
  SELECT i.record_id, i.to_account_id, 'cross_border', false
    FROM core.cross_border_instruction i
   WHERE i.status = 'active';

CREATE OR REPLACE FUNCTION core.fn_can_access(p_record_id uuid, p_account_id uuid, p_edit boolean DEFAULT false)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.v_record_access a
     WHERE a.record_id = p_record_id AND a.account_id = p_account_id AND (NOT p_edit OR a.can_edit)
  )
$$;

CREATE OR REPLACE FUNCTION core.fn_family_owner(p_family_id uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT owner_account_id FROM core.mark_family WHERE id = p_family_id
$$;

-- Is p_other on the other side of a relationship with p_me (appointment or quote request)?
-- SECURITY DEFINER so policies can ask without recursing into each other's RLS.
CREATE OR REPLACE FUNCTION core.fn_is_counterparty(p_other uuid, p_me uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM core.appointment a
                  WHERE (a.owner_account_id = p_me AND a.agency_account_id = p_other) OR (a.agency_account_id = p_me AND a.owner_account_id = p_other))
      OR EXISTS (SELECT 1 FROM core.quote_request_recipient r JOIN core.quote_request q ON q.id = r.quote_request_id
                  WHERE (q.owner_account_id = p_me AND r.agency_account_id = p_other) OR (r.agency_account_id = p_me AND q.owner_account_id = p_other))
$$;

CREATE OR REPLACE FUNCTION core.fn_quote_request_party(p_quote_request_id uuid, p_me uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM core.quote_request q WHERE q.id = p_quote_request_id AND q.owner_account_id = p_me)
      OR EXISTS (SELECT 1 FROM core.quote_request_recipient r WHERE r.quote_request_id = p_quote_request_id AND r.agency_account_id = p_me)
$$;

CREATE OR REPLACE FUNCTION core.fn_quote_request_owner(p_quote_request_id uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT owner_account_id FROM core.quote_request WHERE id = p_quote_request_id
$$;

-- Accounts on the other side of a record from the acting account (owner ↔ accepted agencies).
CREATE OR REPLACE FUNCTION core.fn_counterparties(p_record_id uuid, p_actor_account_id uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
  SELECT DISTINCT a.account_id FROM core.v_record_access a
   WHERE a.record_id = p_record_id AND a.account_id IS DISTINCT FROM p_actor_account_id
$$;

-- -----------------------------------------------------------------------------
-- 11. Audit, record_edit and notification fan-out (item 39)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.trg_audit_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = platform, core, registry, watch, public, pg_temp AS $$
DECLARE
  v_before jsonb; v_after jsonb; v_row_id uuid; v_record_id uuid; v_actor uuid := platform.current_account_id();
  v_changed jsonb; v_cp uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN v_before := to_jsonb(OLD); ELSE v_after := to_jsonb(NEW); END IF;
  IF TG_OP = 'UPDATE' THEN v_before := to_jsonb(OLD); END IF;
  v_row_id := COALESCE((v_after ->> 'id')::uuid, (v_before ->> 'id')::uuid);
  v_record_id := CASE WHEN TG_TABLE_NAME = 'record' THEN v_row_id
                      ELSE COALESCE((v_after ->> 'record_id')::uuid, (v_before ->> 'record_id')::uuid) END;

  INSERT INTO platform.audit_event (account_id, user_id, schema_name, table_name, row_id, record_id, action, before, after)
  VALUES (v_actor, platform.current_user_id(), TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row_id, v_record_id, TG_OP, v_before, v_after);

  -- Record-scoped changes by an account: log the edit and notify the other side.
  IF v_record_id IS NOT NULL AND v_actor IS NOT NULL AND TG_OP IN ('INSERT', 'UPDATE') THEN
    v_changed := jsonb_build_object('op', TG_OP, 'before', v_before, 'after', v_after);
    FOR v_cp IN SELECT core.fn_counterparties(v_record_id, v_actor) LOOP
      INSERT INTO core.record_edit (record_id, user_id, account_id, table_name, changed, notified_account_id)
      VALUES (v_record_id, platform.current_user_id(), v_actor, TG_TABLE_NAME, v_changed, v_cp);
      INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
      VALUES (v_cp, 'in_app', 'record_edited', v_record_id,
              jsonb_build_object('table', TG_TABLE_NAME, 'by_account', v_actor, 'op', TG_OP));
    END LOOP;
    IF NOT FOUND THEN
      INSERT INTO core.record_edit (record_id, user_id, account_id, table_name, changed)
      VALUES (v_record_id, platform.current_user_id(), v_actor, TG_TABLE_NAME, v_changed);
    END IF;
  END IF;
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['record', 'record_class', 'record_registry_scope', 'document', 'record_event', 'timer',
                           'appointment', 'appointment_record', 'cross_border_instruction', 'account', 'app_user',
                           'quote', 'quote_request', 'payment', 'mark_family'] LOOP
    EXECUTE format('CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON core.%I FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row()', t);
  END LOOP;
  EXECUTE 'CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.watch_scope FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row()';
  EXECUTE 'CREATE TRIGGER audit_row AFTER INSERT OR UPDATE OR DELETE ON watch.alert FOR EACH ROW EXECUTE FUNCTION platform.trg_audit_row()';
END $$;

-- -----------------------------------------------------------------------------
-- 12. Lifecycle: stage derivation, timers, deadline arithmetic (items 37, 42, 44)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION registry.fn_current_profile(p_registry_id uuid, p_as_of date DEFAULT current_date)
RETURNS registry.registry_profile LANGUAGE sql STABLE AS $$
  SELECT p.* FROM registry.registry_profile p
   WHERE p.registry_id = p_registry_id AND p.effective_from <= p_as_of
   ORDER BY p.effective_from DESC, p.version DESC LIMIT 1
$$;

-- 23:59 registry-local on the due date; no rollover of the last day (item 44).
CREATE OR REPLACE FUNCTION core.fn_due_at(p_due_date date, p_timezone text) RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT ((p_due_date + time '23:59')::timestamp) AT TIME ZONE COALESCE(p_timezone, 'UTC')
$$;

-- Default event → stage map (Section 7). A profile's status_map overrides per event type.
CREATE OR REPLACE FUNCTION core.fn_default_stage(p_event core.event_type) RETURNS core.stage
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_event
    WHEN 'filed' THEN 'filing_examination'::core.stage
    WHEN 'formal_ok' THEN 'filing_examination'
    WHEN 'office_action' THEN 'filing_examination'
    WHEN 'response_filed' THEN 'filing_examination'
    WHEN 'refused' THEN 'filing_examination'
    WHEN 'accepted' THEN 'acceptance_publication_opposition'
    WHEN 'published' THEN 'acceptance_publication_opposition'
    WHEN 'opposed' THEN 'acceptance_publication_opposition'
    WHEN 'appealed' THEN 'appeals'
    WHEN 'registered' THEN 'registration'
    WHEN 'declaration_of_use' THEN 'registration'
    WHEN 'recordal' THEN 'post_registration_recordals'
    WHEN 'renewal_window' THEN 'renewal_grace_expiry'
    WHEN 'renewed' THEN 'renewal_grace_expiry'
    WHEN 'expired' THEN 'renewal_grace_expiry'
    WHEN 'challenged' THEN 'challenges'
    WHEN 'enforcement' THEN 'enforcement'
    WHEN 'withdrawn' THEN 'pre_filing'
    ELSE NULL   -- cancelled: terminal inside the current stage
  END
$$;

CREATE OR REPLACE FUNCTION core.fn_record_stage(p_record_id uuid, OUT stage core.stage, OUT terminal boolean, OUT status_label jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r core.record; e core.record_event; prof registry.registry_profile; m jsonb; mapped text;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id;
  SELECT * INTO e FROM core.record_event
   WHERE record_id = p_record_id AND (source <> 'suggested' OR confirmed_at IS NOT NULL)
   ORDER BY event_date DESC, created_at DESC LIMIT 1;
  IF e.id IS NULL THEN
    stage := 'pre_filing'; terminal := false; status_label := NULL; RETURN;
  END IF;
  prof := registry.fn_current_profile(r.registry_id, e.event_date);
  m := COALESCE(prof.rules -> 'status_map' -> e.event_type::text, '{}'::jsonb);
  mapped := m ->> 'stage';
  IF mapped IS NOT NULL THEN
    stage := mapped::core.stage;
  ELSE
    stage := COALESCE(core.fn_default_stage(e.event_type), r.stage);
  END IF;
  terminal := COALESCE((m ->> 'terminal')::boolean, e.event_type IN ('refused', 'withdrawn', 'cancelled', 'expired'));
  status_label := COALESCE(m -> 'label',
                           CASE WHEN e.registry_status IS NOT NULL THEN jsonb_build_object('en', e.registry_status, 'ar', e.registry_status) END);
END $$;

-- Timers for one event from the registry profile. A clock with verified=false creates a row
-- awaiting the user's entry and no day count; a clock absent from the profile creates nothing.
CREATE OR REPLACE FUNCTION core.fn_timers_for_event(p_event_id uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  e core.record_event; r core.record; prof registry.registry_profile; tz text;
  k text; spec jsonb; v_due date; v_verified boolean; n integer := 0; base date; months integer;
BEGIN
  SELECT * INTO e FROM core.record_event WHERE id = p_event_id;
  IF e.source = 'suggested' AND e.confirmed_at IS NULL THEN RETURN 0; END IF;
  SELECT * INTO r FROM core.record WHERE id = e.record_id;
  prof := registry.fn_current_profile(r.registry_id, e.event_date);
  IF prof.id IS NULL THEN RETURN 0; END IF;
  tz := prof.rules -> 'calendar' ->> 'timezone';

  -- Registration sets expiry from the term rule (filing_date + N years by default).
  IF e.event_type = 'registered' AND prof.rules ? 'term' THEN
    base := CASE prof.rules -> 'term' ->> 'from' WHEN 'registration_date' THEN e.event_date ELSE COALESCE(r.filing_date, e.event_date) END;
    v_due := base + make_interval(years => COALESCE((prof.rules -> 'term' ->> 'years')::integer, 10));
    UPDATE core.record SET registration_date = COALESCE(registration_date, e.event_date), expiry_date = v_due WHERE id = r.id;
    r.expiry_date := v_due;
  END IF;

  FOR k, spec IN SELECT key, value FROM jsonb_each(prof.rules -> 'timers') LOOP
    CONTINUE WHEN spec ->> 'start_event' IS DISTINCT FROM e.event_type::text;
    -- a clock is verified when its own flag says so, else when the whole profile is marked verified
    v_verified := COALESCE((spec ->> 'verified')::boolean, prof.verified);
    IF NOT v_verified THEN
      INSERT INTO core.timer (record_id, event_id, family, timer_type, source, awaiting_user_entry)
      VALUES (r.id, e.id, 'statutory', k, 'user_entered', true);
      n := n + 1; CONTINUE;
    END IF;
    IF spec ? 'days' THEN
      v_due := e.event_date + (spec ->> 'days')::integer;
    ELSIF spec ? 'months' THEN
      v_due := (e.event_date + make_interval(months => (spec ->> 'months')::integer))::date;
    ELSIF spec ? 'months_before_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := (r.expiry_date - make_interval(months => (spec ->> 'months_before_expiry')::integer))::date;
    ELSIF spec ? 'months_after_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := (r.expiry_date + make_interval(months => (spec ->> 'months_after_expiry')::integer))::date;
    ELSIF spec ? 'at_expiry' AND r.expiry_date IS NOT NULL THEN
      v_due := r.expiry_date;
    ELSE
      CONTINUE;
    END IF;
    INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
    VALUES (r.id, e.id, 'statutory', k, v_due, core.fn_due_at(v_due, tz), 'profile');
    n := n + 1;

    -- Reminders derived at the ruled cadences, e.g. renewal_window: [6, 3, 1] months before expiry.
    IF prof.rules -> 'reminders' ? k AND r.expiry_date IS NOT NULL THEN
      FOR months IN SELECT (x)::integer FROM jsonb_array_elements_text(prof.rules -> 'reminders' -> k) x LOOP
        INSERT INTO core.timer (record_id, event_id, family, timer_type, due_date, due_at, source)
        VALUES (r.id, e.id, 'reminder', format('%s_reminder_%sm', k, months),
                (r.expiry_date - make_interval(months => months))::date,
                core.fn_due_at((r.expiry_date - make_interval(months => months))::date, tz), 'profile');
        n := n + 1;
      END LOOP;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- After an event is inserted or confirmed: recompute stage, (re)flow timers.
CREATE OR REPLACE FUNCTION core.trg_record_event_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE s record;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- date re-flow (item 44): cancel this event's open timers and regenerate
    UPDATE core.timer SET state = 'cancelled' WHERE event_id = NEW.id AND state = 'open';
  END IF;
  PERFORM core.fn_timers_for_event(NEW.id);
  SELECT * INTO s FROM core.fn_record_stage(NEW.record_id);
  UPDATE core.record SET stage = s.stage, terminal = s.terminal, status_label = COALESCE(s.status_label, status_label)
   WHERE id = NEW.record_id AND (stage IS DISTINCT FROM s.stage OR terminal IS DISTINCT FROM s.terminal
                                 OR status_label IS DISTINCT FROM COALESCE(s.status_label, status_label));
  RETURN NULL;
END $$;
CREATE TRIGGER record_event_apply AFTER INSERT OR UPDATE OF event_date, confirmed_at, event_type ON core.record_event
  FOR EACH ROW EXECUTE FUNCTION core.trg_record_event_apply();

-- Mark text normalised on write with the shared normaliser (defined in Section 14 below).
-- POA validity → record.poa_state (Ruled, 6–7 Nov)
CREATE OR REPLACE FUNCTION core.fn_refresh_poa_state(p_record_id uuid) RETURNS void
LANGUAGE sql AS $$
  UPDATE core.record r SET poa_state = (
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.doc_type = 'POA' AND (d.valid_until IS NULL OR d.valid_until >= current_date)) THEN 'present'
      WHEN EXISTS (SELECT 1 FROM core.document d WHERE d.record_id = r.id AND d.doc_type = 'POA') THEN 'expired'
      ELSE 'missing' END::core.poa_state)
  WHERE r.id = p_record_id
$$;
CREATE OR REPLACE FUNCTION core.trg_document_poa() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(NEW.doc_type, OLD.doc_type) = 'POA' THEN
    PERFORM core.fn_refresh_poa_state(COALESCE(NEW.record_id, OLD.record_id));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER document_poa AFTER INSERT OR UPDATE OR DELETE ON core.document FOR EACH ROW EXECUTE FUNCTION core.trg_document_poa();

-- New record created by an appointed agency: put it in the appointment's scope.
CREATE OR REPLACE FUNCTION core.trg_record_scope_for_creator() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE v_actor uuid := platform.current_account_id(); v_owner uuid; v_appt uuid;
BEGIN
  v_owner := core.fn_family_owner(NEW.mark_family_id);
  IF v_actor IS NOT NULL AND v_actor <> v_owner THEN
    SELECT id INTO v_appt FROM core.appointment WHERE owner_account_id = v_owner AND agency_account_id = v_actor AND status = 'accepted' AND ended_at IS NULL;
    IF v_appt IS NOT NULL THEN
      INSERT INTO core.appointment_record (appointment_id, record_id) VALUES (v_appt, NEW.id);
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER record_scope_for_creator AFTER INSERT ON core.record FOR EACH ROW EXECUTE FUNCTION core.trg_record_scope_for_creator();

-- The one state table every page reads (item 44). A view with security_invoker so RLS applies.
CREATE VIEW core.v_record_state WITH (security_invoker = true) AS
  SELECT r.id AS record_id, r.mark_family_id, r.registry_id, g.code AS registry_code,
         r.application_no, r.registration_no, r.filing_date, r.registration_date, r.expiry_date,
         r.mark_text, r.stage, r.status_label, r.terminal, r.entry_mode, r.paid_state, r.poa_state,
         r.watch_active_from IS NOT NULL AS watch_active, r.madrid IS NOT NULL AS is_madrid,
         CASE WHEN r.expiry_date IS NOT NULL THEN (r.expiry_date - current_date) END AS days_remaining,
         nt.timer_type AS next_timer_type, nt.due_date AS next_due_date, nt.due_at AS next_due_at,
         EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type = 'recordal') AS has_recordals,
         EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type = 'challenged') AS has_challenges,
         EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.event_type = 'enforcement') AS has_enforcement,
         EXISTS (SELECT 1 FROM core.record_event e WHERE e.record_id = r.id AND e.source = 'suggested' AND e.confirmed_at IS NULL) AS has_suggestions,
         EXISTS (SELECT 1 FROM core.timer t WHERE t.record_id = r.id AND t.state = 'open' AND t.awaiting_user_entry) AS awaiting_deadline_entry,
         (SELECT count(*) FROM watch.alert a WHERE a.record_id = r.id AND a.status = 'new' AND a.account_id = platform.current_account_id()) AS new_alerts
    FROM core.record r
    JOIN registry.registry g ON g.id = r.registry_id
    LEFT JOIN LATERAL (
      SELECT t.timer_type, t.due_date, t.due_at FROM core.timer t
       WHERE t.record_id = r.id AND t.state = 'open' AND t.due_date IS NOT NULL
       ORDER BY t.due_date LIMIT 1) nt ON true;

-- -----------------------------------------------------------------------------
-- 13. Commerce: price list, pricing and payment procedures (Business Model Section 7; items 32, 45)
-- -----------------------------------------------------------------------------
-- Prices are configuration (CLAUDE.md rule 9). Ruled 29–30 Oct, 7 Nov 2026.
INSERT INTO core.price_list (version, effective_from, rules) VALUES (1, DATE '2026-12-02', '{
  "currency": "AED",
  "vat_rate": 0.05,
  "home_registry": {"base": 370, "base_years": 10, "step_per_year": 37, "floor": 150, "floor_at_years_or_less": 4},
  "extra_registry": 100,
  "watch_only": 100,
  "class_add": 100,
  "free_until_certificate": true,
  "existing_free_until_watch": true,
  "pilot_all_free": true,
  "annual_option": false
}'::jsonb);

-- Whole years from the day the record enters Meesam to expiry; part year counts as full (Ruled 30 Oct).
CREATE OR REPLACE FUNCTION core.fn_years_remaining(p_expiry date, p_as_of date DEFAULT current_date) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT greatest(0, ceil((p_expiry - p_as_of)::numeric / 365.25))::smallint
$$;

CREATE OR REPLACE FUNCTION core.fn_price(p_case core.payment_case, p_expiry date, p_as_of date DEFAULT current_date,
                                         p_pilot boolean DEFAULT false, OUT years_remaining smallint, OUT amount numeric, OUT vat numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE pl jsonb; h jsonb; yrs smallint; computed numeric;
BEGIN
  SELECT rules INTO pl FROM core.price_list WHERE effective_from <= p_as_of ORDER BY effective_from DESC, version DESC LIMIT 1;
  IF pl IS NULL THEN SELECT rules INTO pl FROM core.price_list ORDER BY version DESC LIMIT 1; END IF;
  h := pl -> 'home_registry';
  yrs := CASE WHEN p_expiry IS NULL THEN (h ->> 'base_years')::smallint ELSE core.fn_years_remaining(p_expiry, p_as_of) END;
  years_remaining := yrs;
  IF p_pilot AND COALESCE((pl ->> 'pilot_all_free')::boolean, false) THEN
    amount := 0; vat := 0; RETURN;
  END IF;
  CASE p_case
    WHEN 'registration', 'early_watch', 'existing_watch' THEN
      IF yrs <= (h ->> 'floor_at_years_or_less')::smallint THEN
        computed := (h ->> 'floor')::numeric;
      ELSE
        computed := (h ->> 'base')::numeric - (h ->> 'step_per_year')::numeric * ((h ->> 'base_years')::smallint - least(yrs, (h ->> 'base_years')::smallint));
        computed := greatest(computed, (h ->> 'floor')::numeric);
      END IF;
    WHEN 'extra_registry' THEN computed := (pl ->> 'extra_registry')::numeric;
    WHEN 'watch_only' THEN computed := (pl ->> 'watch_only')::numeric;
    WHEN 'class_add' THEN computed := (pl ->> 'class_add')::numeric;
  END CASE;
  amount := round(computed, 2);
  vat := round(amount * COALESCE((pl ->> 'vat_rate')::numeric, 0), 2);
END $$;

-- sp_pay: one registration payment per record; early/existing watch switches the watch on (item 45; 7 Nov).
CREATE OR REPLACE PROCEDURE core.sp_pay(p_record_id uuid, p_payer_account_id uuid, p_case core.payment_case,
                                        p_amount numeric, p_vat numeric, p_issuer text, p_provider_ref text,
                                        p_years_remaining smallint DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE r core.record;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'record % not found', p_record_id; END IF;
  IF p_case IN ('registration', 'early_watch', 'existing_watch') AND r.paid_state = 'paid' THEN
    RAISE EXCEPTION 'record % is already paid', p_record_id USING ERRCODE = 'unique_violation';
  END IF;
  INSERT INTO core.payment (record_id, payer_account_id, "case", years_remaining, amount, vat, issuer, provider_ref)
  VALUES (p_record_id, p_payer_account_id, p_case, p_years_remaining, p_amount, p_vat, p_issuer, p_provider_ref);
  IF p_case IN ('registration', 'early_watch', 'existing_watch') THEN
    UPDATE core.record SET paid_state = 'paid', watch_active_from = COALESCE(watch_active_from, now()) WHERE id = p_record_id;
  END IF;
END $$;

-- Certificate arrives: registered event, expiry and renewal timers; unpaid → read-only until paid (Ruled 30 Oct, 7 Nov).
CREATE OR REPLACE PROCEDURE core.sp_certificate_received(p_record_id uuid, p_doc_id uuid, p_registration_date date, p_registration_no text DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE r core.record;
BEGIN
  SELECT * INTO r FROM core.record WHERE id = p_record_id FOR UPDATE;
  UPDATE core.record SET registration_no = COALESCE(p_registration_no, registration_no), registration_date = p_registration_date WHERE id = p_record_id;
  INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
  VALUES (p_record_id, 'registered', p_registration_date, 'manual', jsonb_build_object('document_id', p_doc_id), platform.current_account_id());
  IF r.paid_state = 'free_new_pending' AND NOT EXISTS (SELECT 1 FROM core.payment p WHERE p.record_id = p_record_id AND p."case" IN ('registration', 'early_watch')) THEN
    UPDATE core.record SET paid_state = 'read_only_unpaid' WHERE id = p_record_id;
  END IF;
END $$;

-- Ending an appointment removes access at once through v_record_access (S4).
CREATE OR REPLACE PROCEDURE core.sp_end_appointment(p_appointment_id uuid, p_by core.party_side)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE a core.appointment; v_other uuid;
BEGIN
  SELECT * INTO a FROM core.appointment WHERE id = p_appointment_id FOR UPDATE;
  IF a.id IS NULL THEN RAISE EXCEPTION 'appointment % not found', p_appointment_id; END IF;
  UPDATE core.appointment SET status = 'ended', ended_at = now(), ended_by = p_by WHERE id = p_appointment_id;
  v_other := CASE p_by WHEN 'owner' THEN a.agency_account_id ELSE a.owner_account_id END;
  INSERT INTO platform.notification (account_id, channel, kind, payload)
  VALUES (v_other, 'in_app', 'appointment_ended', jsonb_build_object('appointment_id', p_appointment_id, 'by', p_by));
END $$;

-- Owner pass: single use, 30 days; moves the record's family to the redeeming owner (6 Nov; item 39).
CREATE OR REPLACE PROCEDURE core.sp_redeem_pass(p_token text, p_account_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE p core.owner_pass; v_family uuid;
BEGIN
  SELECT * INTO p FROM core.owner_pass WHERE token_hash = digest(p_token, 'sha256') FOR UPDATE;
  IF p.id IS NULL OR p.redeemed_at IS NOT NULL OR p.expires_at < now() THEN
    RAISE EXCEPTION 'pass is invalid, used or expired' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  UPDATE core.owner_pass SET redeemed_at = now(), redeemed_by_account_id = p_account_id WHERE id = p.id;
  SELECT mark_family_id INTO v_family FROM core.record WHERE id = p.record_id;
  UPDATE core.mark_family SET owner_account_id = p_account_id WHERE id = v_family;
  INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
  VALUES (p.issued_by_account_id, 'in_app', 'pass_redeemed', p.record_id, jsonb_build_object('by_account', p_account_id));
END $$;

-- Selecting one quote declines its siblings and raises the appointment request (items 30–31, 39).
CREATE OR REPLACE PROCEDURE core.sp_select_quote(p_quote_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, platform, registry, watch, public, pg_temp AS $$
DECLARE q core.quote; qr core.quote_request;
BEGIN
  SELECT * INTO q FROM core.quote WHERE id = p_quote_id FOR UPDATE;
  SELECT * INTO qr FROM core.quote_request WHERE id = q.quote_request_id;
  IF q.status <> 'sent' THEN RAISE EXCEPTION 'only a sent quote can be selected' USING ERRCODE = 'check_violation'; END IF;
  UPDATE core.quote SET status = 'selected' WHERE id = p_quote_id;
  UPDATE core.quote SET status = 'declined' WHERE quote_request_id = q.quote_request_id AND id <> p_quote_id AND status IN ('draft', 'sent');
  INSERT INTO core.appointment (owner_account_id, agency_account_id, status, requested_by)
  VALUES (qr.owner_account_id, q.agency_account_id, 'requested', 'owner')
  ON CONFLICT DO NOTHING;
  INSERT INTO platform.notification (account_id, channel, kind, record_id, payload)
  VALUES (q.agency_account_id, 'in_app', 'quote_selected', qr.record_id, jsonb_build_object('quote_id', p_quote_id));
END $$;

-- -----------------------------------------------------------------------------
-- 14. Watch normaliser (item 35; 14.2) — rules now, learned later
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION watch.fn_normalise_arabic(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(
           translate(
             regexp_replace(p, '[ً-ْٰـ]', '', 'g'),   -- diacritics, superscript alef, tatweel
             'أإآؤئةى', 'اااويهي'),                                       -- hamza forms, taa marbuta, alef maqsura
           '[^؀-ۿ0-9 ]+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION watch.fn_normalise_latin(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(lower(unaccent(p)), '[^a-z0-9 ]+', ' ', 'g'))
$$;

-- Phonetic key v1: consonant skeleton shared by Arabic and Latin so "Maysam" ~ "ميسم".
CREATE OR REPLACE FUNCTION watch.fn_phonetic_key(p_norm_en text, p_norm_ar text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE s text; a text;
BEGIN
  s := COALESCE(p_norm_en, '');
  s := regexp_replace(s, 'ph', 'f', 'g');
  s := regexp_replace(s, 'c(?=[eiy])', 's', 'g');
  s := regexp_replace(s, '[cqk]', 'k', 'g');
  s := regexp_replace(s, 'x', 'ks', 'g');
  s := regexp_replace(s, 'z', 's', 'g');
  s := regexp_replace(s, '(.)\1', '\1', 'g');
  s := regexp_replace(s, '(?<=.)[aeiouwyh]', '', 'g');
  a := COALESCE(p_norm_ar, '');
  a := translate(a, 'ابتثجحخدذرزسشصضطظعغفقكلمنهويء',
                    'abttjhhdzrzsssdtzagfkklmnhwy');   -- hamza dropped
  a := regexp_replace(a, '(.)\1', '\1', 'g');
  a := regexp_replace(a, '(?<=.)[awyh ]', '', 'g');
  RETURN NULLIF(trim(both ' ' FROM concat_ws('|', NULLIF(s, ''), NULLIF(a, ''))), '');
END $$;

CREATE OR REPLACE FUNCTION watch.fn_normalise_mark(p jsonb, OUT norm jsonb, OUT phonetic text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE k text; v text; out_obj jsonb := '{}'::jsonb; n text;
BEGIN
  IF p IS NULL THEN norm := NULL; phonetic := NULL; RETURN; END IF;
  FOR k, v IN SELECT key, value FROM jsonb_each_text(p) LOOP
    n := CASE k WHEN 'ar' THEN watch.fn_normalise_arabic(v) ELSE watch.fn_normalise_latin(v) END;
    IF n IS NOT NULL AND n <> '' THEN out_obj := out_obj || jsonb_build_object(k, n); END IF;
  END LOOP;
  norm := out_obj;
  phonetic := watch.fn_phonetic_key(out_obj ->> 'en', out_obj ->> 'ar');
END $$;

CREATE OR REPLACE FUNCTION core.trg_record_normalise() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n record;
BEGIN
  SELECT * INTO n FROM watch.fn_normalise_mark(NEW.mark_text);
  NEW.mark_text_norm := n.norm; NEW.phonetic_key := n.phonetic;
  RETURN NEW;
END $$;
CREATE TRIGGER record_normalise BEFORE INSERT OR UPDATE OF mark_text ON core.record FOR EACH ROW EXECUTE FUNCTION core.trg_record_normalise();

CREATE OR REPLACE FUNCTION watch.trg_published_mark_normalise() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE n record;
BEGIN
  SELECT * INTO n FROM watch.fn_normalise_mark(NEW.mark_text);
  NEW.mark_text_norm := n.norm; NEW.phonetic_key := n.phonetic;
  RETURN NEW;
END $$;
CREATE TRIGGER published_mark_normalise BEFORE INSERT OR UPDATE OF mark_text ON watch.published_mark FOR EACH ROW EXECUTE FUNCTION watch.trg_published_mark_normalise();

-- -----------------------------------------------------------------------------
-- 15. Row-level security (Section 6; CLAUDE.md rule 2)
-- -----------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['account', 'app_user', 'appointment', 'appointment_record', 'cross_border_instruction', 'owner_pass',
                           'quote_request', 'quote_request_recipient', 'quote', 'message_thread', 'message', 'mark_family', 'record',
                           'record_class', 'record_registry_scope', 'record_event', 'timer', 'document', 'record_edit', 'payment'] LOOP
    EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['watch_scope', 'alert', 'alert_feedback', 'own_filing_suppression', 'retro_report', 'candidate', 'published_mark', 'comparison_run'] LOOP
    EXECUTE format('ALTER TABLE watch.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['notification', 'audit_event', 'telemetry_event', 'feedback', 'import_batch', 'import_row'] LOOP
    EXECUTE format('ALTER TABLE platform.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- account
CREATE POLICY account_select ON core.account FOR SELECT TO meesam_app USING (
  id = platform.current_account_id()
  OR directory_listed
  OR core.fn_is_counterparty(id, platform.current_account_id()));
CREATE POLICY account_update ON core.account FOR UPDATE TO meesam_app USING (id = platform.current_account_id()) WITH CHECK (id = platform.current_account_id());

-- app_user
CREATE POLICY app_user_all ON core.app_user FOR ALL TO meesam_app
  USING (account_id = platform.current_account_id()) WITH CHECK (account_id = platform.current_account_id());

-- appointment and its records
CREATE POLICY appointment_all ON core.appointment FOR ALL TO meesam_app
  USING (owner_account_id = platform.current_account_id() OR agency_account_id = platform.current_account_id())
  WITH CHECK (owner_account_id = platform.current_account_id() OR agency_account_id = platform.current_account_id());
CREATE POLICY appointment_record_all ON core.appointment_record FOR ALL TO meesam_app
  USING (EXISTS (SELECT 1 FROM core.appointment a WHERE a.id = appointment_id AND (a.owner_account_id = platform.current_account_id() OR a.agency_account_id = platform.current_account_id())))
  WITH CHECK (EXISTS (SELECT 1 FROM core.appointment a WHERE a.id = appointment_id AND (a.owner_account_id = platform.current_account_id() OR a.agency_account_id = platform.current_account_id())));

CREATE POLICY cbi_all ON core.cross_border_instruction FOR ALL TO meesam_app
  USING (from_account_id = platform.current_account_id() OR to_account_id = platform.current_account_id() OR core.fn_can_access(record_id, platform.current_account_id()))
  WITH CHECK (from_account_id = platform.current_account_id() AND core.fn_can_access(record_id, platform.current_account_id(), true));

CREATE POLICY owner_pass_select ON core.owner_pass FOR SELECT TO meesam_app
  USING (issued_by_account_id = platform.current_account_id() OR redeemed_by_account_id = platform.current_account_id());
CREATE POLICY owner_pass_insert ON core.owner_pass FOR INSERT TO meesam_app
  WITH CHECK (issued_by_account_id = platform.current_account_id() AND core.fn_can_access(record_id, platform.current_account_id(), true));

-- quotes
CREATE POLICY quote_request_all ON core.quote_request FOR ALL TO meesam_app
  USING (core.fn_quote_request_party(id, platform.current_account_id()))
  WITH CHECK (owner_account_id = platform.current_account_id());
CREATE POLICY quote_request_recipient_all ON core.quote_request_recipient FOR ALL TO meesam_app
  USING (agency_account_id = platform.current_account_id() OR core.fn_quote_request_owner(quote_request_id) = platform.current_account_id())
  WITH CHECK (core.fn_quote_request_owner(quote_request_id) = platform.current_account_id());
CREATE POLICY quote_select ON core.quote FOR SELECT TO meesam_app
  USING (agency_account_id = platform.current_account_id()
         OR (status <> 'draft' AND core.fn_quote_request_owner(quote_request_id) = platform.current_account_id()));
CREATE POLICY quote_write ON core.quote FOR INSERT TO meesam_app WITH CHECK (agency_account_id = platform.current_account_id());
CREATE POLICY quote_update ON core.quote FOR UPDATE TO meesam_app USING (agency_account_id = platform.current_account_id()) WITH CHECK (agency_account_id = platform.current_account_id());

-- messages
CREATE POLICY thread_all ON core.message_thread FOR ALL TO meesam_app
  USING (owner_account_id = platform.current_account_id() OR agency_account_id = platform.current_account_id())
  WITH CHECK ((owner_account_id = platform.current_account_id() OR agency_account_id = platform.current_account_id()) AND core.fn_can_access(record_id, platform.current_account_id()));
CREATE POLICY message_all ON core.message FOR ALL TO meesam_app
  USING (EXISTS (SELECT 1 FROM core.message_thread t WHERE t.id = thread_id AND (t.owner_account_id = platform.current_account_id() OR t.agency_account_id = platform.current_account_id())))
  WITH CHECK (author_account_id = platform.current_account_id() AND EXISTS (SELECT 1 FROM core.message_thread t WHERE t.id = thread_id AND (t.owner_account_id = platform.current_account_id() OR t.agency_account_id = platform.current_account_id())));

-- families and records
CREATE POLICY mark_family_select ON core.mark_family FOR SELECT TO meesam_app
  USING (owner_account_id = platform.current_account_id()
         OR EXISTS (SELECT 1 FROM core.record r WHERE r.mark_family_id = mark_family.id AND core.fn_can_access(r.id, platform.current_account_id())));
CREATE POLICY mark_family_insert ON core.mark_family FOR INSERT TO meesam_app WITH CHECK (
  owner_account_id = platform.current_account_id()
  OR EXISTS (SELECT 1 FROM core.appointment a WHERE a.owner_account_id = mark_family.owner_account_id AND a.agency_account_id = platform.current_account_id() AND a.status = 'accepted' AND a.ended_at IS NULL));
CREATE POLICY mark_family_update ON core.mark_family FOR UPDATE TO meesam_app USING (owner_account_id = platform.current_account_id()) WITH CHECK (owner_account_id = platform.current_account_id());

CREATE POLICY record_select ON core.record FOR SELECT TO meesam_app USING (core.fn_can_access(id, platform.current_account_id()));
CREATE POLICY record_insert ON core.record FOR INSERT TO meesam_app WITH CHECK (
  core.fn_family_owner(mark_family_id) = platform.current_account_id()
  OR EXISTS (SELECT 1 FROM core.appointment a WHERE a.owner_account_id = core.fn_family_owner(mark_family_id) AND a.agency_account_id = platform.current_account_id() AND a.status = 'accepted' AND a.ended_at IS NULL));
CREATE POLICY record_update ON core.record FOR UPDATE TO meesam_app
  USING (core.fn_can_access(id, platform.current_account_id(), true)) WITH CHECK (core.fn_can_access(id, platform.current_account_id(), true));

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['record_class', 'record_registry_scope', 'record_event', 'timer', 'document'] LOOP
    EXECUTE format('CREATE POLICY %I_select ON core.%I FOR SELECT TO meesam_app USING (core.fn_can_access(record_id, platform.current_account_id()))', t, t);
    EXECUTE format('CREATE POLICY %I_insert ON core.%I FOR INSERT TO meesam_app WITH CHECK (core.fn_can_access(record_id, platform.current_account_id(), true))', t, t);
    EXECUTE format('CREATE POLICY %I_update ON core.%I FOR UPDATE TO meesam_app USING (core.fn_can_access(record_id, platform.current_account_id(), true)) WITH CHECK (core.fn_can_access(record_id, platform.current_account_id(), true))', t, t);
  END LOOP;
END $$;
CREATE POLICY record_edit_select ON core.record_edit FOR SELECT TO meesam_app USING (core.fn_can_access(record_id, platform.current_account_id()));
CREATE POLICY payment_select ON core.payment FOR SELECT TO meesam_app USING (core.fn_can_access(record_id, platform.current_account_id()));
-- payments are written only through core.sp_pay (SECURITY DEFINER); no direct insert policy.

-- watch
CREATE POLICY watch_scope_all ON watch.watch_scope FOR ALL TO meesam_app
  USING (account_id = platform.current_account_id())
  WITH CHECK (account_id = platform.current_account_id() AND core.fn_can_access(record_id, platform.current_account_id(), true));
CREATE POLICY alert_select ON watch.alert FOR SELECT TO meesam_app USING (account_id = platform.current_account_id());
CREATE POLICY alert_update ON watch.alert FOR UPDATE TO meesam_app USING (account_id = platform.current_account_id()) WITH CHECK (account_id = platform.current_account_id());
CREATE POLICY alert_feedback_all ON watch.alert_feedback FOR ALL TO meesam_app
  USING (EXISTS (SELECT 1 FROM watch.alert a WHERE a.id = alert_id AND a.account_id = platform.current_account_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM watch.alert a WHERE a.id = alert_id AND a.account_id = platform.current_account_id()));
CREATE POLICY suppression_all ON watch.own_filing_suppression FOR ALL TO meesam_app
  USING (core.fn_can_access(record_id, platform.current_account_id())) WITH CHECK (core.fn_can_access(record_id, platform.current_account_id(), true));
CREATE POLICY retro_report_select ON watch.retro_report FOR SELECT TO meesam_app USING (account_id = platform.current_account_id());
CREATE POLICY candidate_select ON watch.candidate FOR SELECT TO meesam_app
  USING (EXISTS (SELECT 1 FROM watch.alert a WHERE a.candidate_id = candidate.id AND a.account_id = platform.current_account_id()));
CREATE POLICY published_mark_select ON watch.published_mark FOR SELECT TO meesam_app
  USING (EXISTS (SELECT 1 FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id
                  WHERE c.published_mark_id = published_mark.id AND a.account_id = platform.current_account_id()));
CREATE POLICY comparison_run_select ON watch.comparison_run FOR SELECT TO meesam_app
  USING (EXISTS (SELECT 1 FROM watch.alert a JOIN watch.candidate c ON c.id = a.candidate_id WHERE c.run_id = comparison_run.id AND a.account_id = platform.current_account_id()));

-- platform
CREATE POLICY notification_select ON platform.notification FOR SELECT TO meesam_app USING (account_id = platform.current_account_id());
CREATE POLICY notification_update ON platform.notification FOR UPDATE TO meesam_app USING (account_id = platform.current_account_id()) WITH CHECK (account_id = platform.current_account_id());
CREATE POLICY audit_select ON platform.audit_event FOR SELECT TO meesam_app
  USING (account_id = platform.current_account_id() OR (record_id IS NOT NULL AND core.fn_can_access(record_id, platform.current_account_id())));
CREATE POLICY telemetry_insert ON platform.telemetry_event FOR INSERT TO meesam_app WITH CHECK (account_id IS NOT DISTINCT FROM platform.current_account_id());
CREATE POLICY feedback_all ON platform.feedback FOR ALL TO meesam_app USING (account_id = platform.current_account_id()) WITH CHECK (account_id IS NOT DISTINCT FROM platform.current_account_id());
CREATE POLICY import_batch_all ON platform.import_batch FOR ALL TO meesam_app USING (account_id = platform.current_account_id()) WITH CHECK (account_id = platform.current_account_id());
CREATE POLICY import_row_all ON platform.import_row FOR ALL TO meesam_app
  USING (EXISTS (SELECT 1 FROM platform.import_batch b WHERE b.id = batch_id AND b.account_id = platform.current_account_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM platform.import_batch b WHERE b.id = batch_id AND b.account_id = platform.current_account_id()));

-- -----------------------------------------------------------------------------
-- 16. Grants
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA core, registry, watch, platform TO meesam_app, meesam_worker, meesam_staff, meesam_admin, meesam_readonly;
GRANT USAGE ON SCHEMA prospect TO meesam_worker, meesam_staff, meesam_admin, meesam_readonly;   -- never meesam_app

-- app: read/write within RLS; registry data read-only; never deletes (history is kept)
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA core TO meesam_app;
GRANT SELECT ON ALL TABLES IN SCHEMA registry TO meesam_app;
GRANT SELECT, INSERT, UPDATE ON watch.watch_scope, watch.alert, watch.alert_feedback, watch.own_filing_suppression TO meesam_app;
GRANT SELECT ON watch.candidate, watch.published_mark, watch.comparison_run, watch.retro_report, watch.threshold, watch.publication_issue, watch.publication_source TO meesam_app;
GRANT SELECT, INSERT, UPDATE ON platform.notification, platform.feedback, platform.import_batch, platform.import_row TO meesam_app;
GRANT INSERT ON platform.telemetry_event TO meesam_app;
GRANT SELECT ON platform.audit_event, platform.language TO meesam_app;
REVOKE INSERT, UPDATE ON core.payment, core.record_edit, core.price_list, core.document_type FROM meesam_app;

-- worker, staff, admin: full data access (bypass RLS); readonly: select
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, registry, watch, prospect, platform TO meesam_worker, meesam_admin;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA watch, prospect, platform TO meesam_staff;
GRANT SELECT ON ALL TABLES IN SCHEMA core, registry TO meesam_staff;
GRANT SELECT ON ALL TABLES IN SCHEMA core, registry, watch, prospect, platform TO meesam_readonly;
-- Functions are EXECUTE to PUBLIC by default; take that back and grant explicitly.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA core, registry, watch, prospect, platform FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA core FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core, registry, watch, platform TO meesam_app, meesam_worker, meesam_staff, meesam_admin;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA core TO meesam_app, meesam_worker, meesam_admin;
REVOKE EXECUTE ON FUNCTION platform.claim_jobs(text, integer, text[]), platform.complete_job(uuid), platform.fail_job(uuid, text), platform.requeue_stale_jobs(interval),
                          platform.ensure_month_partitions(text, text, integer), platform.ensure_year_partitions(text, text, integer),
                          watch.ensure_published_mark_partitions(uuid, integer) FROM meesam_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, registry, watch, prospect, platform REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA core, registry, watch, platform GRANT SELECT ON TABLES TO meesam_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, registry, watch, prospect, platform GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO meesam_worker, meesam_admin;

-- -----------------------------------------------------------------------------
-- 17. Seed: launch registries and second wave (ST.3 codes confirmed 12 Nov 2026), Nice classes
-- -----------------------------------------------------------------------------
INSERT INTO registry.registry (code, name, country, supported, launch_wave) VALUES
  ('AE', '{"en": "United Arab Emirates — Ministry of Economy and Tourism", "ar": "الإمارات العربية المتحدة — وزارة الاقتصاد والسياحة"}', 'AE', false, 1),
  ('GB', '{"en": "United Kingdom — Intellectual Property Office", "ar": "المملكة المتحدة — مكتب الملكية الفكرية"}', 'GB', false, 1),
  ('EM', '{"en": "European Union Intellectual Property Office", "ar": "مكتب الاتحاد الأوروبي للملكية الفكرية"}', NULL, false, 1),
  ('US', '{"en": "United States Patent and Trademark Office", "ar": "مكتب براءات الاختراع والعلامات التجارية الأمريكي"}', 'US', false, 1),
  ('SA', '{"en": "Saudi Arabia — Saudi Authority for Intellectual Property", "ar": "المملكة العربية السعودية — الهيئة السعودية للملكية الفكرية"}', 'SA', false, 1),
  ('OM', '{"en": "Oman — Ministry of Commerce, Industry and Investment Promotion", "ar": "عُمان — وزارة التجارة والصناعة وترويج الاستثمار"}', 'OM', false, 1),
  ('KW', '{"en": "Kuwait — Ministry of Commerce and Industry", "ar": "الكويت — وزارة التجارة والصناعة"}', 'KW', false, 1),
  ('QA', '{"en": "Qatar — Ministry of Commerce and Industry", "ar": "قطر — وزارة التجارة والصناعة"}', 'QA', false, 1),
  ('BH', '{"en": "Bahrain — Ministry of Industry and Commerce", "ar": "البحرين — وزارة الصناعة والتجارة"}', 'BH', false, 1),
  ('WO', '{"en": "WIPO — Madrid System", "ar": "الويبو — نظام مدريد"}', NULL, false, NULL),
  ('CN', '{"en": "China — National Intellectual Property Administration", "ar": "الصين — الإدارة الوطنية للملكية الفكرية"}', 'CN', false, 2),
  ('IN', '{"en": "India — Office of the Controller General of Patents, Designs and Trade Marks", "ar": "الهند — مكتب المراقب العام للبراءات والتصاميم والعلامات التجارية"}', 'IN', false, 2),
  ('TR', '{"en": "Türkiye — Turkish Patent and Trademark Office", "ar": "تركيا — المكتب التركي للبراءات والعلامات التجارية"}', 'TR', false, 2),
  ('JO', '{"en": "Jordan — Ministry of Industry, Trade and Supply", "ar": "الأردن — وزارة الصناعة والتجارة والتموين"}', 'JO', false, 2),
  ('EG', '{"en": "Egypt — Egyptian Trademark Office", "ar": "مصر — مكتب العلامات التجارية المصري"}', 'EG', false, 2),
  ('XX', '{"en": "Unknown registry", "ar": "مكتب غير معروف"}', NULL, false, NULL);
-- supported flips to true per registry when its profile row from the Registry Profiles annex is loaded and verified (Step 3.3).

-- Nice classes 1–45: numbers now; bilingual headings and terms are loaded from the official
-- WIPO/MoET data files in Step 3.3 (the data files are the source, not this migration).
INSERT INTO registry.nice_class (number, heading)
SELECT n, jsonb_build_object('en', format('Class %s', n), 'ar', format('الفئة %s', n)) FROM generate_series(1, 45) n;

COMMIT;
