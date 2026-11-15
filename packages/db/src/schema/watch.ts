import { boolean, char, date, index, integer, jsonb, numeric, pgSchema, smallint, text, time, timestamp, unique, uuid } from "drizzle-orm/pg-core";
import { base, bytea, vector, type I18nText } from "./common.js";
import { account, appUser, record } from "./core.js";
import { registry } from "./registry.js";

export const watchSchema = pgSchema("watch");

export const stream = watchSchema.enum("stream", ["national_bulletin", "madrid_designations", "wipo_gazette", "uspto_tmog", "other"]);
export const sourceFormat = watchSchema.enum("source_format", ["pdf", "xml", "json", "html", "api"]);
export const fetchStatus = watchSchema.enum("fetch_status", ["fetched", "failed", "retried", "parsed", "verified"]);
export const fetchOutcome = watchSchema.enum("fetch_outcome", ["fetched", "not_yet_published", "failed", "recovered"]);
export const frequency = watchSchema.enum("frequency", ["weekly", "fortnightly", "monthly", "irregular"]);
export const verifyState = watchSchema.enum("verify_state", ["ai_extracted", "human_verified", "waived"]);
export const riskBand = watchSchema.enum("risk_band", ["high", "medium", "low"]);
export const alertStatus = watchSchema.enum("alert_status", ["new", "reviewing", "dismissed", "relevant", "actioned"]);
export const feedbackVerdict = watchSchema.enum("feedback_verdict", ["relevant", "not_relevant", "already_known"]);
export const thresholdScope = watchSchema.enum("threshold_scope", ["global", "registry", "account"]);

export const publicationSource = watchSchema.table(
  "publication_source",
  {
    ...base,
    registryId: uuid("registry_id")
      .notNull()
      .references(() => registry.id),
    stream: stream("stream").notNull(),
    fetchSpec: jsonb("fetch_spec").$type<{ url_pattern?: string; parser?: string; auth?: string; [k: string]: unknown }>().notNull().default({}),
    format: sourceFormat("format").notNull(),
    cadence: text("cadence").notNull().default("weekly"),
    active: boolean("active").notNull().default(false),
  },
  (t) => [unique().on(t.registryId, t.stream)],
);

export const publicationSchedule = watchSchema.table("publication_schedule", {
  ...base,
  sourceId: uuid("source_id")
    .notNull()
    .unique()
    .references(() => publicationSource.id),
  frequency: frequency("frequency").notNull(),
  weekday: smallint("weekday"),
  localTime: time("local_time"),
  timezone: text("timezone").notNull(),
  expectedNext: date("expected_next"),
});

export const publicationIssue = watchSchema.table(
  "publication_issue",
  {
    ...base,
    sourceId: uuid("source_id")
      .notNull()
      .references(() => publicationSource.id),
    issueNo: text("issue_no").notNull(),
    publishedOn: date("published_on"),
    fetchedAt: timestamp("fetched_at", { withTimezone: true }),
    objectKey: text("object_key"),
    sha256: bytea("sha256").unique(),
    fetchStatus: fetchStatus("fetch_status").notNull().default("fetched"),
    recoveryLog: jsonb("recovery_log").$type<unknown[]>().notNull().default([]),
  },
  (t) => [unique().on(t.sourceId, t.issueNo)],
);

export const fetchRun = watchSchema.table(
  "fetch_run",
  {
    ...base,
    sourceId: uuid("source_id")
      .notNull()
      .references(() => publicationSource.id),
    issueId: uuid("issue_id").references(() => publicationIssue.id),
    startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
    finishedAt: timestamp("finished_at", { withTimezone: true }),
    outcome: fetchOutcome("outcome"),
    attempt: integer("attempt").notNull().default(1),
    detail: jsonb("detail").$type<Record<string, unknown>>().notNull().default({}),
  },
  (t) => [index("fetch_run_source_id_started_at_idx").on(t.sourceId, t.startedAt)],
);

/** Partitioned by registry then year; primary key is (registry_id, publication_date, id). Read via Drizzle, DDL owned by SQL. */
export const publishedMark = watchSchema.table("published_mark", {
  id: uuid("id").notNull().defaultRandom(),
  issueId: uuid("issue_id").notNull(),
  registryId: uuid("registry_id").notNull(),
  publicationDate: date("publication_date").notNull(),
  applicationNo: text("application_no"),
  markText: jsonb("mark_text").$type<I18nText>(),
  markTextNorm: jsonb("mark_text_norm").$type<I18nText>(),
  phoneticKey: text("phonetic_key"),
  markImageKey: text("mark_image_key"),
  phash: bytea("phash"),
  classes: smallint("classes").array().notNull().default([]),
  applicantName: text("applicant_name"),
  applicantCountry: char("applicant_country", { length: 2 }),
  agentName: text("agent_name"),
  oppositionDeadline: date("opposition_deadline"),
  extraction: jsonb("extraction").$type<Record<string, unknown>>().notNull().default({}),
  verifyState: verifyState("verify_state").notNull().default("ai_extracted"),
  verifiedByUserId: uuid("verified_by_user_id"),
  prospectOwnerId: uuid("prospect_owner_id"),
  prospectAgentId: uuid("prospect_agent_id"),
  dinoEmbedding: vector(768)("dino_embedding"),
  siglipEmbedding: vector(768)("siglip_embedding"),
  embeddingEngine: text("embedding_engine"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const watchScope = watchSchema.table(
  "watch_scope",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    accountId: uuid("account_id")
      .notNull()
      .references(() => account.id),
    registryId: uuid("registry_id")
      .notNull()
      .references(() => registry.id),
    classes: smallint("classes").array(),
    countries: char("countries", { length: 2 }).array(),
    setByUserId: uuid("set_by_user_id").references(() => appUser.id),
  },
  (t) => [unique().on(t.recordId, t.accountId, t.registryId)],
);

export const comparisonRun = watchSchema.table("comparison_run", {
  ...base,
  issueId: uuid("issue_id").references(() => publicationIssue.id),
  importBatchId: uuid("import_batch_id"),
  startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
  finishedAt: timestamp("finished_at", { withTimezone: true }),
  engineVersion: text("engine_version").notNull(),
  recordsCompared: integer("records_compared").notNull().default(0),
  candidates: integer("candidates").notNull().default(0),
});

/** Partitioned yearly on created_at; key is (id, created_at). */
export const candidate = watchSchema.table("candidate", {
  id: uuid("id").notNull().defaultRandom(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  runId: uuid("run_id").notNull(),
  publishedMarkId: uuid("published_mark_id").notNull(),
  recordId: uuid("record_id").notNull(),
  scoreText: numeric("score_text", { precision: 5, scale: 4 }),
  scorePhonetic: numeric("score_phonetic", { precision: 5, scale: 4 }),
  scoreImage: numeric("score_image", { precision: 5, scale: 4 }),
  scoreCrossMode: numeric("score_cross_mode", { precision: 5, scale: 4 }),
  score: numeric("score", { precision: 5, scale: 4 }).notNull(),
  classOverlap: smallint("class_overlap").array().notNull().default([]),
  explanation: jsonb("explanation").$type<Record<string, unknown>>().notNull().default({}),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const alert = watchSchema.table(
  "alert",
  {
    ...base,
    candidateId: uuid("candidate_id").notNull(),
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    registryId: uuid("registry_id")
      .notNull()
      .references(() => registry.id),
    accountId: uuid("account_id")
      .notNull()
      .references(() => account.id),
    riskBand: riskBand("risk_band").notNull(),
    status: alertStatus("status").notNull().default("new"),
    oppositionDeadline: date("opposition_deadline"),
    remindedAt: timestamp("reminded_at", { withTimezone: true }).array().notNull().default([]),
  },
  (t) => [unique().on(t.candidateId, t.accountId), index("alert_account_id_risk_band_status_idx").on(t.accountId, t.riskBand, t.status)],
);

export const alertFeedback = watchSchema.table("alert_feedback", {
  ...base,
  alertId: uuid("alert_id")
    .notNull()
    .references(() => alert.id),
  userId: uuid("user_id")
    .notNull()
    .references(() => appUser.id),
  verdict: feedbackVerdict("verdict").notNull(),
  note: text("note"),
});

export const ownFilingSuppression = watchSchema.table(
  "own_filing_suppression",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    publishedMarkId: uuid("published_mark_id").notNull(),
  },
  (t) => [unique().on(t.recordId, t.publishedMarkId)],
);

export const threshold = watchSchema.table("threshold", {
  ...base,
  scope: thresholdScope("scope").notNull(),
  scopeId: uuid("scope_id"),
  bandHigh: numeric("band_high", { precision: 5, scale: 4 }).notNull(),
  bandMedium: numeric("band_medium", { precision: 5, scale: 4 }).notNull(),
  floor: numeric("floor", { precision: 5, scale: 4 }).notNull().default("0.5"),
  version: integer("version").notNull().default(1),
});

export const retroReport = watchSchema.table("retro_report", {
  ...base,
  importBatchId: uuid("import_batch_id").notNull().unique(),
  accountId: uuid("account_id")
    .notNull()
    .references(() => account.id),
  runId: uuid("run_id").references(() => comparisonRun.id),
  summary: jsonb("summary").$type<Record<string, unknown>>().notNull().default({}),
  deliveredAt: timestamp("delivered_at", { withTimezone: true }),
});
