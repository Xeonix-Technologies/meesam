import { boolean, index, integer, jsonb, pgSchema, smallint, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { base, timestamps } from "./common.js";

export const platformSchema = pgSchema("platform");

export const notificationChannel = platformSchema.enum("notification_channel", ["in_app", "email"]);
export const notificationStatus = platformSchema.enum("notification_status", ["queued", "sent", "read", "failed"]);
export const jobStatus = platformSchema.enum("job_status", ["queued", "running", "done", "failed", "dead"]);
export const importStatus = platformSchema.enum("import_status", ["staged", "validated", "committed", "cancelled"]);

/** Languages are data (14.2); the UI locale list reads this table. */
export const language = platformSchema.table("language", {
  code: text("code").primaryKey(),
  script: text("script").notNull(),
  direction: text("direction").notNull(),
  normaliser: text("normaliser").notNull(),
  active: boolean("active").notNull().default(true),
  ...timestamps,
});

/** Partitioned monthly; the Drizzle definition is read-only (the migration owns the DDL). */
export const auditEvent = platformSchema.table("audit_event", {
  id: uuid("id").notNull(),
  occurredAt: timestamp("occurred_at", { withTimezone: true }).notNull(),
  accountId: uuid("account_id"),
  userId: uuid("user_id"),
  dbRole: text("db_role").notNull(),
  schemaName: text("schema_name").notNull(),
  tableName: text("table_name").notNull(),
  rowId: uuid("row_id"),
  recordId: uuid("record_id"),
  action: text("action").notNull(),
  before: jsonb("before").$type<Record<string, unknown>>(),
  after: jsonb("after").$type<Record<string, unknown>>(),
});

export const notification = platformSchema.table(
  "notification",
  {
    ...base,
    accountId: uuid("account_id").notNull(),
    userId: uuid("user_id"),
    channel: notificationChannel("channel").notNull(),
    kind: text("kind").notNull(),
    recordId: uuid("record_id"),
    payload: jsonb("payload").$type<Record<string, unknown>>().notNull().default({}),
    status: notificationStatus("status").notNull().default("queued"),
    sentAt: timestamp("sent_at", { withTimezone: true }),
    readAt: timestamp("read_at", { withTimezone: true }),
    dedupeKey: text("dedupe_key"),
  },
  (t) => [index("notification_account_id_status_created_at_idx").on(t.accountId, t.status, t.createdAt)],
);

export const telemetryEvent = platformSchema.table("telemetry_event", {
  id: uuid("id").notNull(),
  occurredAt: timestamp("occurred_at", { withTimezone: true }).notNull(),
  accountId: uuid("account_id"),
  userId: uuid("user_id"),
  event: text("event").notNull(),
  properties: jsonb("properties").$type<Record<string, unknown>>().notNull().default({}),
});

export const feedback = platformSchema.table("feedback", {
  ...base,
  accountId: uuid("account_id"),
  userId: uuid("user_id"),
  page: text("page"),
  body: text("body").notNull(),
  locale: text("locale"),
});

export const importBatch = platformSchema.table("import_batch", {
  ...base,
  accountId: uuid("account_id").notNull(),
  userId: uuid("user_id"),
  fileObjectKey: text("file_object_key"),
  status: importStatus("status").notNull().default("staged"),
  summary: jsonb("summary").$type<Record<string, unknown>>().notNull().default({}),
  committedAt: timestamp("committed_at", { withTimezone: true }),
});

export const importRow = platformSchema.table("import_row", {
  ...base,
  batchId: uuid("batch_id")
    .notNull()
    .references(() => importBatch.id),
  rowNo: integer("row_no").notNull(),
  raw: jsonb("raw").$type<Record<string, string>>().notNull(),
  warnings: jsonb("warnings").$type<unknown[]>().notNull().default([]),
  errors: jsonb("errors").$type<unknown[]>().notNull().default([]),
  recordId: uuid("record_id"),
});

/** The queue (14.11): claimed with platform.claim_jobs(), never read directly by the app. */
export const job = platformSchema.table("job", {
  ...base,
  kind: text("kind").notNull(),
  payload: jsonb("payload").$type<Record<string, unknown>>().notNull().default({}),
  status: jobStatus("status").notNull().default("queued"),
  runAt: timestamp("run_at", { withTimezone: true }).notNull().defaultNow(),
  priority: smallint("priority").notNull().default(100),
  attempts: integer("attempts").notNull().default(0),
  maxAttempts: integer("max_attempts").notNull().default(5),
  lockedAt: timestamp("locked_at", { withTimezone: true }),
  lockedBy: text("locked_by"),
  finishedAt: timestamp("finished_at", { withTimezone: true }),
  lastError: text("last_error"),
  dedupeKey: text("dedupe_key"),
});

export type Job = typeof job.$inferSelect;
