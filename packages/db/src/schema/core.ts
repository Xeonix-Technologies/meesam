import { sql } from "drizzle-orm";
import { bigint, boolean, char, date, index, integer, jsonb, numeric, pgSchema, smallint, text, timestamp, unique, uniqueIndex, uuid } from "drizzle-orm/pg-core";
import { base, bytea, citext, timestamps, type I18nText } from "./common.js";
import { niceClass, registry } from "./registry.js";
import { language } from "./platform.js";

export const coreSchema = pgSchema("core");

// ---------------------------------------------------------------- enums
export const accountKind = coreSchema.enum("account_kind", ["owner_individual", "owner_company", "agency_office"]);
export const verificationMethod = coreSchema.enum("verification_method", ["staff", "ai"]);
export const userRole = coreSchema.enum("user_role", ["company_admin", "tm_manager", "agency_admin", "agent", "viewer"]);
export const userStatus = coreSchema.enum("user_status", ["invited", "active", "suspended", "removed"]);
export const appointmentStatus = coreSchema.enum("appointment_status", ["requested", "accepted", "declined", "ended"]);
export const partySide = coreSchema.enum("party_side", ["owner", "agency"]);
export const instructionStatus = coreSchema.enum("instruction_status", ["requested", "active", "ended", "declined"]);
export const quoteStatus = coreSchema.enum("quote_status", ["draft", "sent", "selected", "declined"]);
export const markType = coreSchema.enum("mark_type", ["word", "device", "combined"]);
/** Nine stages in the ruled order (item 42). */
export const stage = coreSchema.enum("stage", [
  "pre_filing",
  "filing_examination",
  "acceptance_publication_opposition",
  "appeals",
  "registration",
  "post_registration_recordals",
  "renewal_grace_expiry",
  "challenges",
  "enforcement",
]);
export const entryMode = coreSchema.enum("entry_mode", ["new_filing", "existing", "bulk_import", "pass"]);
export const paidState = coreSchema.enum("paid_state", ["free_new_pending", "filing_paid", "free_loaded", "read_only_unpaid", "paid"]);
export const poaState = coreSchema.enum("poa_state", ["present", "missing", "expired"]);
export const scopeKind = coreSchema.enum("scope_kind", ["filed", "watch_only"]);
export const eventType = coreSchema.enum("event_type", [
  "filed",
  "formal_ok",
  "office_action",
  "response_filed",
  "accepted",
  "published",
  "opposed",
  "appealed",
  "registered",
  "declaration_of_use",
  "recordal",
  "renewal_window",
  "renewed",
  "expired",
  "challenged",
  "enforcement",
  "cancelled",
  "refused",
  "withdrawn",
]);
export const eventSource = coreSchema.enum("event_source", ["manual", "ai_extract", "registry_feed", "bulk_import", "suggested"]);
export const timerFamily = coreSchema.enum("timer_family", ["statutory", "watch", "reminder"]);
export const timerState = coreSchema.enum("timer_state", ["open", "met", "missed", "cancelled"]);
export const timerSource = coreSchema.enum("timer_source", ["profile", "user_entered", "alert"]);
export const extractionStatus = coreSchema.enum("extraction_status", ["pending", "extracted", "accepted", "rejected"]);
export const paymentCase = coreSchema.enum("payment_case", ["registration", "early_watch", "existing_watch", "extra_registry", "watch_only", "class_add", "filing"]);

// ---------------------------------------------------------------- identity and parties
export const account = coreSchema.table("account", {
  ...base,
  kind: accountKind("kind").notNull(),
  name: jsonb("name").$type<I18nText>().notNull(),
  country: char("country", { length: 2 }).notNull(),
  verifiedAt: timestamp("verified_at", { withTimezone: true }),
  verificationMethod: verificationMethod("verification_method"),
  directoryListed: boolean("directory_listed").notNull().default(false),
  licenceNo: text("licence_no"),
  contact: jsonb("contact").$type<Record<string, unknown>>().notNull().default({}),
});

export const appUser = coreSchema.table(
  "app_user",
  {
    ...base,
    accountId: uuid("account_id")
      .notNull()
      .references(() => account.id),
    email: citext("email").notNull().unique(),
    name: text("name").notNull(),
    role: userRole("role").notNull(),
    locale: text("locale")
      .notNull()
      .default("en")
      .references(() => language.code),
    status: userStatus("status").notNull().default("invited"),
    passwordHash: text("password_hash"),
    lastLoginAt: timestamp("last_login_at", { withTimezone: true }),
  },
  (t) => [index("app_user_account_id_idx").on(t.accountId)],
);

export const appointment = coreSchema.table(
  "appointment",
  {
    ...base,
    ownerAccountId: uuid("owner_account_id")
      .notNull()
      .references(() => account.id),
    agencyAccountId: uuid("agency_account_id")
      .notNull()
      .references(() => account.id),
    status: appointmentStatus("status").notNull().default("requested"),
    requestedBy: partySide("requested_by").notNull(),
    requestedAt: timestamp("requested_at", { withTimezone: true }).notNull().defaultNow(),
    acceptedAt: timestamp("accepted_at", { withTimezone: true }),
    endedAt: timestamp("ended_at", { withTimezone: true }),
    endedBy: partySide("ended_by"),
  },
  (t) => [
    uniqueIndex("appointment_one_open")
      .on(t.ownerAccountId, t.agencyAccountId)
      .where(sql`status IN ('requested', 'accepted')`),
    index("appointment_agency_account_id_status_idx").on(t.agencyAccountId, t.status),
  ],
);

export const markFamily = coreSchema.table(
  "mark_family",
  {
    ...base,
    ownerAccountId: uuid("owner_account_id")
      .notNull()
      .references(() => account.id),
    name: jsonb("name").$type<I18nText>().notNull(),
    markType: markType("mark_type").notNull(),
  },
  (t) => [index("mark_family_owner_account_id_idx").on(t.ownerAccountId)],
);

/** One mark at one registry — the priced unit (items 20, 32; Business Model case 1). */
export const record = coreSchema.table(
  "record",
  {
    ...base,
    markFamilyId: uuid("mark_family_id")
      .notNull()
      .references(() => markFamily.id),
    registryId: uuid("registry_id")
      .notNull()
      .references(() => registry.id),
    applicationNo: text("application_no"),
    registrationNo: text("registration_no"),
    filingDate: date("filing_date"),
    registrationDate: date("registration_date"),
    expiryDate: date("expiry_date"),
    markText: jsonb("mark_text").$type<I18nText>(),
    markTextNorm: jsonb("mark_text_norm").$type<I18nText>(),
    phoneticKey: text("phonetic_key"),
    markImageDocId: uuid("mark_image_doc_id"),
    stage: stage("stage").notNull().default("pre_filing"),
    statusLabel: jsonb("status_label").$type<I18nText>(),
    terminal: boolean("terminal").notNull().default(false),
    entryMode: entryMode("entry_mode").notNull(),
    paidState: paidState("paid_state").notNull(),
    watchActiveFrom: timestamp("watch_active_from", { withTimezone: true }),
    agentOfRecordAccountId: uuid("agent_of_record_account_id").references(() => account.id),
    poaState: poaState("poa_state").notNull().default("missing"),
    madrid: jsonb("madrid").$type<{
      role: "basis" | "designation";
      international_registration_no?: string;
      designations?: string[];
      central_renewal_date?: string;
      dependency_until?: string;
    }>(),
    warnings: jsonb("warnings").$type<unknown[]>().notNull().default([]),
  },
  (t) => [
    uniqueIndex("record_one_per_application")
      .on(t.registryId, t.applicationNo)
      .where(sql`application_no IS NOT NULL`),
    index("record_mark_family_id_idx").on(t.markFamilyId),
    index("record_registry_id_idx").on(t.registryId),
    index("record_expiry_date_idx").on(t.expiryDate),
  ],
);

export const appointmentRecord = coreSchema.table(
  "appointment_record",
  {
    ...base,
    appointmentId: uuid("appointment_id")
      .notNull()
      .references(() => appointment.id),
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    addedAt: timestamp("added_at", { withTimezone: true }).notNull().defaultNow(),
    removedAt: timestamp("removed_at", { withTimezone: true }),
  },
  (t) => [index("appointment_record_record_id_idx").on(t.recordId)],
);

/** The 14 vault type codes (item 14.16). */
export const documentType = coreSchema.table("document_type", {
  code: text("code").primaryKey(),
  name: jsonb("name").$type<I18nText>().notNull(),
  ...timestamps,
});

export const document = coreSchema.table(
  "document",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    docType: text("doc_type")
      .notNull()
      .references(() => documentType.code),
    serialNo: text("serial_no"),
    objectKey: text("object_key").notNull(),
    fileName: text("file_name").notNull(),
    contentType: text("content_type"),
    sizeBytes: bigint("size_bytes", { mode: "number" }),
    sha256: bytea("sha256").notNull(),
    extracted: jsonb("extracted").$type<Record<string, unknown>>(),
    extractionStatus: extractionStatus("extraction_status").notNull().default("pending"),
    validUntil: date("valid_until"),
    uploadedByUserId: uuid("uploaded_by_user_id").references(() => appUser.id),
    uploadedByAccountId: uuid("uploaded_by_account_id").references(() => account.id),
  },
  (t) => [index("document_record_id_doc_type_idx").on(t.recordId, t.docType), uniqueIndex("document_object_key").on(t.objectKey)],
);

export const crossBorderInstruction = coreSchema.table("cross_border_instruction", {
  ...base,
  fromAccountId: uuid("from_account_id")
    .notNull()
    .references(() => account.id),
  toAccountId: uuid("to_account_id")
    .notNull()
    .references(() => account.id),
  recordId: uuid("record_id")
    .notNull()
    .references(() => record.id),
  status: instructionStatus("status").notNull().default("requested"),
  legalRequestDocId: uuid("legal_request_doc_id").references(() => document.id),
  poaDocId: uuid("poa_doc_id").references(() => document.id),
  endedAt: timestamp("ended_at", { withTimezone: true }),
});

export const ownerPass = coreSchema.table("owner_pass", {
  ...base,
  recordId: uuid("record_id")
    .notNull()
    .references(() => record.id),
  issuedByAccountId: uuid("issued_by_account_id")
    .notNull()
    .references(() => account.id),
  tokenHash: bytea("token_hash").notNull().unique(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  redeemedAt: timestamp("redeemed_at", { withTimezone: true }),
  redeemedByAccountId: uuid("redeemed_by_account_id").references(() => account.id),
});

/** An agency's invitation to an owner by e-mail (0026); becomes an appointment request once the owner's account is verified. */
export const ownerInvite = coreSchema.table("owner_invite", {
  id: uuid("id").primaryKey().defaultRandom(),
  agencyAccountId: uuid("agency_account_id")
    .notNull()
    .references(() => account.id),
  email: citext("email").notNull(),
  message: text("message"),
  invitedByUserId: uuid("invited_by_user_id").references(() => appUser.id),
  status: text("status").notNull().default("pending"),
  appointmentId: uuid("appointment_id").references(() => appointment.id),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  closedAt: timestamp("closed_at", { withTimezone: true }),
});

export const quoteRequest = coreSchema.table("quote_request", {
  ...base,
  ownerAccountId: uuid("owner_account_id")
    .notNull()
    .references(() => account.id),
  recordId: uuid("record_id").references(() => record.id),
  brief: jsonb("brief").$type<Record<string, unknown>>().notNull().default({}),
  sentToCount: integer("sent_to_count").notNull().default(0),
});

export const quoteRequestRecipient = coreSchema.table(
  "quote_request_recipient",
  {
    ...base,
    quoteRequestId: uuid("quote_request_id")
      .notNull()
      .references(() => quoteRequest.id),
    agencyAccountId: uuid("agency_account_id")
      .notNull()
      .references(() => account.id),
  },
  (t) => [unique().on(t.quoteRequestId, t.agencyAccountId)],
);

export const quote = coreSchema.table(
  "quote",
  {
    ...base,
    quoteRequestId: uuid("quote_request_id")
      .notNull()
      .references(() => quoteRequest.id),
    agencyAccountId: uuid("agency_account_id")
      .notNull()
      .references(() => account.id),
    amount: numeric("amount", { precision: 12, scale: 2 }).notNull(),
    currency: char("currency", { length: 3 }).notNull().default("AED"),
    status: quoteStatus("status").notNull().default("draft"),
    note: jsonb("note").$type<I18nText>(),
    sentByUserId: uuid("sent_by_user_id").references(() => appUser.id),
    sentAt: timestamp("sent_at", { withTimezone: true }),
  },
  (t) => [unique().on(t.quoteRequestId, t.agencyAccountId)],
);

export const messageThread = coreSchema.table(
  "message_thread",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    ownerAccountId: uuid("owner_account_id")
      .notNull()
      .references(() => account.id),
    agencyAccountId: uuid("agency_account_id")
      .notNull()
      .references(() => account.id),
  },
  (t) => [unique().on(t.recordId, t.ownerAccountId, t.agencyAccountId)],
);

export const message = coreSchema.table(
  "message",
  {
    ...base,
    threadId: uuid("thread_id")
      .notNull()
      .references(() => messageThread.id),
    authorUserId: uuid("author_user_id")
      .notNull()
      .references(() => appUser.id),
    authorAccountId: uuid("author_account_id")
      .notNull()
      .references(() => account.id),
    body: text("body").notNull(),
  },
  (t) => [index("message_thread_id_created_at_idx").on(t.threadId, t.createdAt)],
);

// ---------------------------------------------------------------- commerce
export const priceList = coreSchema.table("price_list", {
  ...base,
  version: integer("version").notNull().unique(),
  effectiveFrom: date("effective_from").notNull(),
  rules: jsonb("rules").$type<Record<string, unknown>>().notNull(),
});

export const payment = coreSchema.table(
  "payment",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    payerAccountId: uuid("payer_account_id")
      .notNull()
      .references(() => account.id),
    case: paymentCase("case").notNull(),
    yearsRemaining: smallint("years_remaining"),
    amount: numeric("amount", { precision: 12, scale: 2 }).notNull(),
    vat: numeric("vat", { precision: 12, scale: 2 }).notNull().default("0"),
    currency: char("currency", { length: 3 }).notNull().default("AED"),
    issuer: text("issuer").notNull(),
    providerRef: text("provider_ref"),
    paidAt: timestamp("paid_at", { withTimezone: true }).notNull().defaultNow(),
    refundable: boolean("refundable").notNull().default(false),
  },
  (t) => [index("payment_record_id_idx").on(t.recordId)],
);

// ---------------------------------------------------------------- marks: classes, scopes, events, timers
export const recordClass = coreSchema.table(
  "record_class",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    niceClassId: uuid("nice_class_id")
      .notNull()
      .references(() => niceClass.id),
    addedAt: timestamp("added_at", { withTimezone: true }).notNull().defaultNow(),
    terms: jsonb("terms").$type<I18nText[]>(),
    feePaymentId: uuid("fee_payment_id").references(() => payment.id),
  },
  (t) => [unique().on(t.recordId, t.niceClassId)],
);

export const recordRegistryScope = coreSchema.table(
  "record_registry_scope",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    registryId: uuid("registry_id")
      .notNull()
      .references(() => registry.id),
    kind: scopeKind("kind").notNull(),
    addedAt: timestamp("added_at", { withTimezone: true }).notNull().defaultNow(),
    paymentId: uuid("payment_id").references(() => payment.id),
  },
  (t) => [unique().on(t.recordId, t.registryId)],
);

/** Append-only; drives stage and timers (item 37). Suggested events move nothing until confirmed (item 44). */
export const recordEvent = coreSchema.table(
  "record_event",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    eventType: eventType("event_type").notNull(),
    eventDate: date("event_date").notNull(),
    source: eventSource("source").notNull().default("manual"),
    registryStatus: text("registry_status"),
    detail: jsonb("detail").$type<Record<string, unknown>>().notNull().default({}),
    publicationIssueId: uuid("publication_issue_id"),
    confirmedAt: timestamp("confirmed_at", { withTimezone: true }),
    confirmedByUserId: uuid("confirmed_by_user_id").references(() => appUser.id),
    verifiedByUserId: uuid("verified_by_user_id").references(() => appUser.id),
    createdByAccountId: uuid("created_by_account_id").references(() => account.id),
  },
  (t) => [index("record_event_record_id_event_date_idx").on(t.recordId, t.eventDate, t.createdAt)],
);

export const timer = coreSchema.table(
  "timer",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    eventId: uuid("event_id").references(() => recordEvent.id),
    family: timerFamily("family").notNull(),
    timerType: text("timer_type").notNull(),
    dueDate: date("due_date"),
    dueAt: timestamp("due_at", { withTimezone: true }),
    state: timerState("state").notNull().default("open"),
    source: timerSource("source").notNull(),
    awaitingUserEntry: boolean("awaiting_user_entry").notNull().default(false),
    alertId: uuid("alert_id"),
    metAt: timestamp("met_at", { withTimezone: true }),
  },
  (t) => [index("timer_record_id_state_due_date_idx").on(t.recordId, t.state, t.dueDate)],
);

export const recordEdit = coreSchema.table(
  "record_edit",
  {
    ...base,
    recordId: uuid("record_id")
      .notNull()
      .references(() => record.id),
    userId: uuid("user_id").references(() => appUser.id),
    accountId: uuid("account_id").references(() => account.id),
    tableName: text("table_name").notNull(),
    changed: jsonb("changed").$type<{ op: string; before: unknown; after: unknown }>().notNull(),
    notifiedAccountId: uuid("notified_account_id").references(() => account.id),
  },
  (t) => [index("record_edit_record_id_created_at_idx").on(t.recordId, t.createdAt)],
);
