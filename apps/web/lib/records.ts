import { sql } from "drizzle-orm";
import { withAccount, withRole, type Db, type RegistryProfileRules } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";
import { runChecks, type IntakeData, type IntakeStage, type Warning } from "./checks";

type Row = Record<string, unknown>;
const rows = (r: unknown) => r as unknown as Row[];
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });

// ---------------------------------------------------------------- reference data
export interface RegistryRef { id: string; code: string; name: I18nText; supported: boolean }

export async function listRegistries(onlySupported = true): Promise<RegistryRef[]> {
  const r = await withRole(db(), "meesam_app", (tx) =>
    tx.execute(sql`SELECT id, code, name, supported FROM registry.registry WHERE code <> 'XX' AND (${!onlySupported} OR supported) ORDER BY launch_wave NULLS LAST, code`),
  );
  return rows(r).map((x) => ({ id: String(x.id), code: String(x.code), name: x.name as I18nText, supported: Boolean(x.supported) }));
}

export async function profileRules(registryCode: string): Promise<RegistryProfileRules | null> {
  const r = await withRole(db(), "meesam_app", (tx) =>
    tx.execute(sql`SELECT p.rules FROM registry.registry g, LATERAL registry.fn_current_profile(g.id) p WHERE g.code = ${registryCode}`),
  );
  return (rows(r)[0]?.rules as RegistryProfileRules | undefined) ?? null;
}

export interface NiceClassRef { id: string; number: number; heading: I18nText }
export async function listNiceClasses(): Promise<NiceClassRef[]> {
  const r = await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT id, number, heading FROM registry.nice_class ORDER BY number`));
  return rows(r).map((x) => ({ id: String(x.id), number: Number(x.number), heading: x.heading as I18nText }));
}

// ---------------------------------------------------------------- intake drafts (4.7)
export interface Upload { object_key: string; doc_type: string; file_name: string; content_type: string; size: number; sha256: string; uploaded_at: string }
export interface Draft { id: string; step: number; data: IntakeData; uploads: Upload[]; warnings: Warning[]; status: string; record_id: string | null }

const toDraft = (x: Row): Draft => ({
  id: String(x.id), step: Number(x.step), data: (x.data as IntakeData) ?? {}, uploads: (x.uploads as Upload[]) ?? [],
  warnings: (x.warnings as Warning[]) ?? [], status: String(x.status), record_id: (x.record_id as string | null) ?? null,
});

export async function getDraft(s: Session, id: string): Promise<Draft | null> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT * FROM core.intake_draft WHERE id = ${id}::uuid`));
  const x = rows(r)[0];
  return x ? toDraft(x) : null;
}

export async function createDraft(s: Session, kind = "existing"): Promise<string> {
  const r = await withAccount(db(), ctx(s), (tx) =>
    tx.execute(sql`INSERT INTO core.intake_draft (account_id, user_id, kind) VALUES (${s.accountId}::uuid, ${s.userId}::uuid, ${kind}) RETURNING id`),
  );
  return String(rows(r)[0]!.id);
}

export async function saveDraftStep(s: Session, id: string, step: number, patch: Partial<IntakeData>): Promise<void> {
  await withAccount(db(), ctx(s), (tx) =>
    tx.execute(sql`UPDATE core.intake_draft SET data = data || ${JSON.stringify(patch)}::jsonb, step = greatest(step, ${step}::smallint)
                   WHERE id = ${id}::uuid AND status = 'open'`),
  );
}

export async function addDraftUpload(s: Session, id: string, upload: Upload): Promise<void> {
  await withAccount(db(), ctx(s), (tx) =>
    tx.execute(sql`UPDATE core.intake_draft SET uploads = uploads || ${JSON.stringify([upload])}::jsonb WHERE id = ${id}::uuid AND status = 'open'`),
  );
}

export async function removeDraftUpload(s: Session, id: string, objectKey: string): Promise<void> {
  await withAccount(db(), ctx(s), (tx) =>
    tx.execute(sql`UPDATE core.intake_draft SET uploads = COALESCE((SELECT jsonb_agg(u) FROM jsonb_array_elements(uploads) u WHERE u ->> 'object_key' <> ${objectKey}), '[]'::jsonb)
                   WHERE id = ${id}::uuid AND status = 'open'`),
  );
}

export async function saveDraftWarnings(s: Session, id: string, warnings: Warning[]): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE core.intake_draft SET warnings = ${JSON.stringify(warnings)}::jsonb WHERE id = ${id}::uuid`));
}

/** Step 7: everything accepted — create family, record, classes, events, documents; close historical clocks. */
export async function commitDraft(s: Session, draft: Draft, confirmations: Record<string, string>): Promise<string> {
  const data = draft.data;
  if (!data.registry_code || !data.stage || !data.mark_type) throw new Error("draft incomplete");
  const rules = await profileRules(data.registry_code);
  const warnings = runChecks(data, rules).map((w) => {
    const key = `${w.code}:${w.field}`;
    return confirmations[key] !== undefined ? { ...w, confirmed_note: confirmations[key], confirmed_at: new Date().toISOString() } : w;
  });
  const markText: I18nText = {};
  if (data.mark_text_ar) markText.ar = data.mark_text_ar;
  if (data.mark_text_en) markText.en = data.mark_text_en;
  const familyName: I18nText = Object.keys(markText).length ? markText : { en: data.application_no ?? "mark" };

  return withAccount(db(), ctx(s), async (tx) => {
    const reg = rows(await tx.execute(sql`SELECT id FROM registry.registry WHERE code = ${data.registry_code}`))[0];
    if (!reg) throw new Error("registry not found");
    const registryId = String(reg.id);
    const ownerAccountId = data.manager === "agency" && s.accountKind === "agency_office" ? null : s.accountId;
    // An agency adding a client's mark without an appointment: the family is owned by the agency's
    // account until an owner redeems a pass (System Description 4.4). RULING NEEDED for the final model.
    const fam = rows(await tx.execute(sql`INSERT INTO core.mark_family (owner_account_id, name, mark_type) VALUES (${ownerAccountId ?? s.accountId}::uuid, ${JSON.stringify(familyName)}::jsonb, ${data.mark_type}::core.mark_type) RETURNING id`))[0]!;
    const rec = rows(await tx.execute(sql`
      INSERT INTO core.record (mark_family_id, registry_id, application_no, registration_no, filing_date, mark_text, entry_mode, paid_state, warnings,
                               agent_of_record_account_id)
      VALUES (${String(fam.id)}::uuid, ${registryId}::uuid, ${data.application_no ?? null}, ${data.registration_no ?? null}, ${data.filing_date ?? null}::date,
              ${Object.keys(markText).length ? JSON.stringify(markText) : null}::jsonb, 'existing', 'free_loaded', ${JSON.stringify(warnings)}::jsonb,
              ${data.manager === "agency" && data.agency_account_id ? data.agency_account_id : null}::uuid)
      RETURNING id`))[0]!;
    const recordId = String(rec.id);

    for (const n of data.classes ?? []) {
      await tx.execute(sql`INSERT INTO core.record_class (record_id, nice_class_id, terms)
                           SELECT ${recordId}::uuid, id, ${data.goods ? JSON.stringify([{ en: data.goods }]) : null}::jsonb FROM registry.nice_class WHERE number = ${n}
                           ON CONFLICT DO NOTHING`);
    }
    await tx.execute(sql`INSERT INTO core.record_registry_scope (record_id, registry_id, kind) VALUES (${recordId}::uuid, ${registryId}::uuid, 'filed')`);

    // events in order; each one recomputes stage and timers (0001 trigger)
    const events: Array<[string, string | undefined]> = [["filed", data.filing_date]];
    const st = data.stage as IntakeStage;
    const rank = ["filed", "accepted", "published", "fee_paid", "registered", "renewed"].indexOf(st);
    if (rank >= 1) events.push(["accepted", data.acceptance_date]);
    if (rank >= 2) events.push(["published", data.publication_date]);
    if (rank >= 4) events.push(["registered", data.registration_date]);
    if (rank >= 5) events.push(["renewed", data.renewal_date]);
    for (const [type, date] of events) {
      if (!date) continue;
      await tx.execute(sql`INSERT INTO core.record_event (record_id, event_type, event_date, source, detail, created_by_account_id)
                           VALUES (${recordId}::uuid, ${type}::core.event_type, ${date}::date, 'manual', ${JSON.stringify({ via: "intake" })}::jsonb, ${s.accountId}::uuid)`);
    }
    if (st === "fee_paid") await tx.execute(sql`UPDATE core.timer SET state = 'met', met_at = now() WHERE record_id = ${recordId}::uuid AND timer_type = 'pay_registration' AND state = 'open'`);
    // the certificate's own dates win over the computed ones (certificate information is editable, item 37)
    if (data.registration_date || data.expiry_date) {
      await tx.execute(sql`UPDATE core.record SET registration_date = COALESCE(${data.registration_date ?? null}::date, registration_date),
                                                  expiry_date = COALESCE(${data.expiry_date ?? null}::date, expiry_date) WHERE id = ${recordId}::uuid`);
    }
    await tx.execute(sql`SELECT core.fn_close_historical_timers(${recordId}::uuid)`);

    // documents from the draft's uploads
    for (const u of draft.uploads) {
      await tx.execute(sql`INSERT INTO core.document (record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_user_id, uploaded_by_account_id, extraction_status)
                           VALUES (${recordId}::uuid, ${u.doc_type}, ${u.object_key}, ${u.file_name}, ${u.content_type}, ${u.size}, decode(${u.sha256}, 'hex'), ${s.userId}::uuid, ${s.accountId}::uuid, 'pending')`);
    }
    await tx.execute(sql`UPDATE core.intake_draft SET status = 'committed', record_id = ${recordId}::uuid, warnings = ${JSON.stringify(warnings)}::jsonb WHERE id = ${draft.id}::uuid`);
    return recordId;
  });
}

// ---------------------------------------------------------------- records
export interface RecordState {
  record_id: string; mark_family_id: string; registry_id: string; registry_code: string; application_no: string | null; registration_no: string | null;
  filing_date: string | null; registration_date: string | null; expiry_date: string | null; mark_text: I18nText | null; stage: string; status_label: I18nText | null;
  terminal: boolean; entry_mode: string; paid_state: string; poa_state: string; watch_active: boolean; is_madrid: boolean; days_remaining: number | null;
  next_timer_type: string | null; next_due_date: string | null; has_suggestions: boolean; awaiting_deadline_entry: boolean; new_alerts: number;
  warnings: Warning[]; holding_agency: I18nText | null; mark_type: "word" | "device" | "combined";
}

export async function listPortfolio(s: Session): Promise<RecordState[]> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT v.*, r.warnings, f.mark_type,
           (SELECT a2.name FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id JOIN core.account a2 ON a2.id = a.agency_account_id
             WHERE ar.record_id = v.record_id AND ar.removed_at IS NULL AND a.status = 'accepted' AND a.ended_at IS NULL LIMIT 1) AS holding_agency
      FROM core.v_record_state v JOIN core.record r ON r.id = v.record_id JOIN core.mark_family f ON f.id = r.mark_family_id
     ORDER BY v.stage, v.next_due_date NULLS LAST, r.created_at DESC`));
  return rows(r) as unknown as RecordState[];
}

export interface RecordDetail extends RecordState {
  classes: Array<{ number: number; heading: I18nText; terms: I18nText[] | null }>;
  timers: Array<{ id: string; timer_type: string; family: string; due_date: string | null; due_at: string | null; state: string; awaiting_user_entry: boolean; source: string }>;
  events: Array<{ id: string; event_type: string; event_date: string; source: string; registry_status: string | null; detail: Row; confirmed_at: string | null; created_at: string; created_by_account: I18nText | null }>;
  documents: Array<{ id: string; doc_type: string; file_name: string; object_key: string; valid_until: string | null; created_at: string; size_bytes: number | null }>;
  edits: Array<{ id: string; table_name: string; account: I18nText | null; created_at: string }>;
  rules: RegistryProfileRules | null;
  madrid: Row | null;
  agent_of_record: I18nText | null;
  can_edit: boolean;
}

export async function getRecord(s: Session, id: string): Promise<RecordDetail | null> {
  return withAccount(db(), ctx(s), async (tx) => {
    const base = rows(await tx.execute(sql`
      SELECT v.*, r.warnings, r.madrid, (SELECT mark_type FROM core.mark_family WHERE id = r.mark_family_id) AS mark_type,
             core.fn_can_access(r.id, ${s.accountId}::uuid, true) AS can_edit,
             (SELECT name FROM core.account WHERE id = r.agent_of_record_account_id) AS agent_of_record,
             (SELECT a2.name FROM core.appointment a JOIN core.appointment_record ar ON ar.appointment_id = a.id JOIN core.account a2 ON a2.id = a.agency_account_id
               WHERE ar.record_id = r.id AND ar.removed_at IS NULL AND a.status = 'accepted' AND a.ended_at IS NULL LIMIT 1) AS holding_agency,
             (SELECT p.rules FROM registry.fn_current_profile(r.registry_id) p) AS rules
        FROM core.v_record_state v JOIN core.record r ON r.id = v.record_id WHERE r.id = ${id}::uuid`))[0];
    if (!base) return null;
    const classes = rows(await tx.execute(sql`SELECT c.number, c.heading, rc.terms FROM core.record_class rc JOIN registry.nice_class c ON c.id = rc.nice_class_id WHERE rc.record_id = ${id}::uuid ORDER BY c.number`));
    const timers = rows(await tx.execute(sql`SELECT id, timer_type, family, due_date, due_at, state, awaiting_user_entry, source FROM core.timer WHERE record_id = ${id}::uuid ORDER BY state = 'open' DESC, due_date NULLS LAST`));
    const events = rows(await tx.execute(sql`SELECT e.id, e.event_type, e.event_date, e.source, e.registry_status, e.detail, e.confirmed_at, e.created_at, a.name AS created_by_account
                                             FROM core.record_event e LEFT JOIN core.account a ON a.id = e.created_by_account_id WHERE e.record_id = ${id}::uuid ORDER BY e.event_date DESC, e.created_at DESC`));
    const documents = rows(await tx.execute(sql`SELECT id, doc_type, file_name, object_key, valid_until, created_at, size_bytes FROM core.document WHERE record_id = ${id}::uuid ORDER BY created_at DESC`));
    const edits = rows(await tx.execute(sql`SELECT e.id, e.table_name, a.name AS account, e.created_at FROM core.record_edit e LEFT JOIN core.account a ON a.id = e.account_id WHERE e.record_id = ${id}::uuid ORDER BY e.created_at DESC LIMIT 50`));
    return { ...(base as unknown as RecordState), classes, timers, events, documents, edits, rules: (base.rules as RegistryProfileRules) ?? null, madrid: (base.madrid as Row) ?? null, agent_of_record: (base.agent_of_record as I18nText) ?? null, can_edit: Boolean(base.can_edit) } as unknown as RecordDetail;
  });
}

/** 3.7 Record a stage change: one event, timers recomputed by the database. */
export async function addStageChange(s: Session, recordId: string, eventType: string, eventDate: string, number: string | null, registryStatus: string | null): Promise<void> {
  await withAccount(db(), ctx(s), async (tx) => {
    await tx.execute(sql`INSERT INTO core.record_event (record_id, event_type, event_date, source, registry_status, detail, created_by_account_id)
                         VALUES (${recordId}::uuid, ${eventType}::core.event_type, ${eventDate}::date, 'manual', ${registryStatus}, ${JSON.stringify(number ? { number } : {})}::jsonb, ${s.accountId}::uuid)`);
    if (eventType === "registered" && number) await tx.execute(sql`UPDATE core.record SET registration_no = COALESCE(registration_no, ${number}) WHERE id = ${recordId}::uuid`);
    if (eventType === "filed" && number) await tx.execute(sql`UPDATE core.record SET application_no = COALESCE(application_no, ${number}) WHERE id = ${recordId}::uuid`);
  });
}

/** Certificate information is editable (item 37). */
export async function updateCertificate(s: Session, recordId: string, patch: { registration_no?: string | null; registration_date?: string | null; expiry_date?: string | null; application_no?: string | null; filing_date?: string | null }): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    UPDATE core.record SET registration_no = COALESCE(${patch.registration_no ?? null}, registration_no),
                           registration_date = COALESCE(${patch.registration_date ?? null}::date, registration_date),
                           expiry_date = COALESCE(${patch.expiry_date ?? null}::date, expiry_date),
                           application_no = COALESCE(${patch.application_no ?? null}, application_no),
                           filing_date = COALESCE(${patch.filing_date ?? null}::date, filing_date)
     WHERE id = ${recordId}::uuid`));
}

/** A user-entered deadline for a clock the profile could not supply (item 44). */
export async function enterDeadline(s: Session, timerId: string, dueDate: string, timezone: string): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    UPDATE core.timer SET due_date = ${dueDate}::date, due_at = core.fn_due_at(${dueDate}::date, ${timezone}), awaiting_user_entry = false, source = 'user_entered'
     WHERE id = ${timerId}::uuid AND awaiting_user_entry`));
}

export async function addDocument(s: Session, recordId: string, doc: { doc_type: string; object_key: string; file_name: string; content_type: string; size: number; sha256: string; valid_until?: string | null }): Promise<string> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    INSERT INTO core.document (record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, valid_until, uploaded_by_user_id, uploaded_by_account_id, serial_no)
    VALUES (${recordId}::uuid, ${doc.doc_type}, ${doc.object_key}, ${doc.file_name}, ${doc.content_type}, ${doc.size}, decode(${doc.sha256}, 'hex'), ${doc.valid_until ?? null}::date, ${s.userId}::uuid, ${s.accountId}::uuid,
            core.fn_next_doc_serial(${recordId}::uuid, ${doc.doc_type}))
    RETURNING id`));
  return String(rows(r)[0]!.id);
}

export async function getDocument(s: Session, id: string): Promise<{ object_key: string; file_name: string; content_type: string | null } | null> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT object_key, file_name, content_type FROM core.document WHERE id = ${id}::uuid`));
  const x = rows(r)[0];
  return x ? { object_key: String(x.object_key), file_name: String(x.file_name), content_type: (x.content_type as string | null) ?? null } : null;
}

export async function recordNumbers(s: Session, recordId: string): Promise<{ registration_no: string | null; application_no: string | null } | null> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT registration_no, application_no FROM core.record WHERE id = ${recordId}::uuid`));
  const x = rows(r)[0];
  return x ? { registration_no: (x.registration_no as string | null) ?? null, application_no: (x.application_no as string | null) ?? null } : null;
}

// ---------------------------------------------------------------- dashboard (Owner 3.2 / Agency 3.2)
export interface DashboardData {
  stageCounts: Record<string, number>;
  nextDates: Array<{ timer_id: string; record_id: string; timer_type: string; due_date: string | null; days_remaining: number | null; mark_text: I18nText | null; registry_code: string; awaiting_user_entry: boolean; with_agency: I18nText | null }>;
  newAlerts: number;
  pending: { quotes_received: number; appointments_requested: number; unpaid_records: number; awaiting_deadlines: number; suggestions: number };
}

export async function dashboard(s: Session): Promise<DashboardData> {
  return withAccount(db(), ctx(s), async (tx) => {
    const counts = rows(await tx.execute(sql`SELECT stage, count(*)::int AS n FROM core.v_record_state GROUP BY stage`));
    const next = rows(await tx.execute(sql`
      SELECT n.timer_id, n.record_id, n.timer_type, n.due_date, n.days_remaining, n.mark_text, n.registry_code, n.awaiting_user_entry,
             (SELECT name FROM core.account WHERE id = n.holding_agency_id AND n.holding_agency_id <> ${s.accountId}::uuid) AS with_agency
        FROM core.v_next_dates n WHERE n.due_date IS NOT NULL OR n.awaiting_user_entry
       ORDER BY n.awaiting_user_entry DESC, n.due_date NULLS LAST LIMIT 8`));
    const alerts = rows(await tx.execute(sql`SELECT count(*)::int AS n FROM watch.alert WHERE status = 'new'`))[0];
    const pending = rows(await tx.execute(sql`
      SELECT (SELECT count(*)::int FROM core.quote q JOIN core.quote_request qr ON qr.id = q.quote_request_id WHERE qr.owner_account_id = ${s.accountId}::uuid AND q.status = 'sent') AS quotes_received,
             (SELECT count(*)::int FROM core.appointment WHERE status = 'requested') AS appointments_requested,
             (SELECT count(*)::int FROM core.v_record_state WHERE paid_state = 'read_only_unpaid') AS unpaid_records,
             (SELECT count(*)::int FROM core.v_record_state WHERE awaiting_deadline_entry) AS awaiting_deadlines,
             (SELECT count(*)::int FROM core.v_record_state WHERE has_suggestions) AS suggestions`))[0]!;
    const stageCounts: Record<string, number> = {};
    for (const c of counts) stageCounts[String(c.stage)] = Number(c.n);
    return { stageCounts, nextDates: next as unknown as DashboardData["nextDates"], newAlerts: Number(alerts?.n ?? 0), pending: pending as unknown as DashboardData["pending"] };
  });
}

export type { Db };
