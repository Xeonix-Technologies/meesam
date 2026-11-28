import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import { INTAKE_STAGES, runChecks, type IntakeData, type IntakeStage, type Warning } from "./checks";
import { insertLoadedRecord, numberProblem, profileRules } from "./records";
import type { Session } from "./session";

/**
 * Bulk import of existing trademarks from a spreadsheet saved as CSV (System Description 4.7 "Portfolio import";
 * Data Architecture Section 9 item 2). A file is staged row by row, its columns are mapped to Meesam's fields,
 * each row is checked, and the rows that can be read are loaded by the same rules as "Add existing trademark".
 * Consistency checks are advisory (Ruled 10 Nov 2026): a row with warnings is still loaded and keeps them;
 * only a row that cannot be read at all stays behind with its reason.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

/** Rows per file: 5,000 (Founder ruling 27 Nov 2026; the speed test on staging passed the same day), or what `IMPORT_MAX_ROWS` says. */
export const MAX_IMPORT_ROWS = Math.min(20000, Math.max(1, Math.floor(Number(process.env.IMPORT_MAX_ROWS)) || 5000));
export const MAX_IMPORT_MB = 10;
export const MAX_IMPORT_BYTES = MAX_IMPORT_MB * 1024 * 1024;
/** Rows loaded side by side. */
const LOAD_WORKERS = 4;

/** The fields a column can be mapped to, in template order. */
export const IMPORT_FIELDS = ["client", "registry", "mark_text_en", "mark_text_ar", "mark_type", "classes", "goods", "stage", "application_no", "filing_date",
  "acceptance_date", "publication_date", "registration_no", "registration_date", "expiry_date", "renewal_date"] as const;
export type ImportField = (typeof IMPORT_FIELDS)[number];
/** The fields offered to this account: the client column is an agency's (Founder ruling 27 Nov 2026); an owner's marks are its own. */
export const fieldsFor = (s: Session): ImportField[] => IMPORT_FIELDS.filter((f) => f !== "client" || s.accountKind === "agency_office");
const DATE_FIELDS: ImportField[] = ["filing_date", "acceptance_date", "publication_date", "registration_date", "expiry_date", "renewal_date"];

/** Header names recognised without asking (lower-cased, punctuation removed). The template uses the first of each. */
const HEADER_ALIASES: Record<ImportField, string[]> = {
  client: ["client", "client name", "customer", "owner", "owner name", "applicant", "proprietor", "holder", "العميل", "اسم العميل", "المالك", "مالك العلامة", "اسم المالك", "مقدم الطلب"],
  registry: ["registry", "country", "jurisdiction", "office", "السجل", "الدولة", "البلد"],
  mark_text_en: ["mark english", "mark", "trademark", "mark name", "trade mark", "name", "mark en", "العلامة بالانجليزية", "العلامة بالإنجليزية"],
  mark_text_ar: ["mark arabic", "mark ar", "arabic", "العلامة", "العلامة بالعربية", "اسم العلامة"],
  mark_type: ["mark type", "type", "نوع العلامة", "النوع"],
  classes: ["classes", "class", "nice classes", "nice class", "الفئات", "الفئة", "الأصناف", "الصنف"],
  goods: ["goods and services", "goods", "services", "specification", "السلع والخدمات", "السلع"],
  stage: ["stage", "status", "المرحلة", "الحالة"],
  application_no: ["application number", "application no", "app no", "filing number", "رقم الطلب"],
  filing_date: ["filing date", "application date", "filed", "تاريخ الإيداع", "تاريخ الطلب"],
  acceptance_date: ["acceptance date", "accepted", "تاريخ القبول"],
  publication_date: ["publication date", "published", "تاريخ النشر"],
  registration_no: ["registration number", "registration no", "reg no", "certificate number", "رقم التسجيل"],
  registration_date: ["registration date", "registered", "تاريخ التسجيل"],
  expiry_date: ["expiry date", "expiry", "expires", "expiration date", "renewal due", "تاريخ الانتهاء", "تاريخ انتهاء الحماية"],
  renewal_date: ["renewal date", "renewed", "last renewal", "تاريخ التجديد"],
};
const norm = (v: string) => v.toLowerCase().replace(/[_\-./()#:]+/g, " ").replace(/\s+/g, " ").trim();

/** RFC 4180 CSV, with the delimiter detected from the first line (comma, semicolon or tab) and a leading BOM removed. */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^﻿/, "");
  const first = src.split(/\r?\n/, 1)[0] ?? "";
  const count = (ch: string) => first.split(ch).length - 1;
  const delim = count("\t") > count(",") && count("\t") >= count(";") ? "\t" : count(";") > count(",") ? ";" : ",";
  const out: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]!;
    if (quoted) {
      if (ch === '"') { if (src[i + 1] === '"') { cell += '"'; i++; } else quoted = false; }
      else cell += ch;
    } else if (ch === '"' && cell === "") quoted = true;
    else if (ch === delim) { row.push(cell); cell = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && src[i + 1] === "\n") i++;
      row.push(cell); cell = "";
      if (row.some((c) => c.trim() !== "")) out.push(row);
      row = [];
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim() !== "")) out.push(row);
  return out.map((r) => r.map((c) => c.trim()));
}

/** Suggests a field for each header; a field is suggested once. */
export function autoMap(headers: string[], fields: readonly ImportField[] = IMPORT_FIELDS): Record<string, ImportField | ""> {
  const taken = new Set<string>();
  const map: Record<string, ImportField | ""> = {};
  headers.forEach((h, i) => {
    const key = norm(h);
    let hit: ImportField | "" = "";
    for (const f of fields) {
      if (taken.has(f)) continue;
      if (HEADER_ALIASES[f].some((a) => norm(a) === key)) { hit = f; break; }
    }
    if (hit) taken.add(hit);
    map[String(i)] = hit;
  });
  return map;
}

/** A date as typed in a spreadsheet → YYYY-MM-DD. Day comes first in DD/MM/YYYY; a spreadsheet serial number is accepted. */
export function parseDate(v: string): string | null {
  const s = v.trim();
  if (!s) return null;
  let m = /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/.exec(s);
  let y = 0, mo = 0, d = 0;
  if (m) { y = Number(m[1]); mo = Number(m[2]); d = Number(m[3]); }
  else if ((m = /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/.exec(s))) { d = Number(m[1]); mo = Number(m[2]); y = Number(m[3]); }
  else if ((m = /^(\d{1,2})[-\s]([A-Za-z]{3,9})[-\s,]+(\d{4})$/.exec(s))) {
    const idx = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].indexOf(m[2]!.slice(0, 3).toLowerCase());
    if (idx < 0) return null;
    d = Number(m[1]); mo = idx + 1; y = Number(m[3]);
  } else if (/^\d{5}$/.test(s)) {
    const t = new Date(Date.UTC(1899, 11, 30) + Number(s) * 86400000);   // spreadsheet serial day
    return t.toISOString().slice(0, 10);
  } else return null;
  const t = new Date(Date.UTC(y, mo - 1, d));
  if (y < 1870 || y > 2200 || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return null;
  return t.toISOString().slice(0, 10);
}

export interface RegistryRef { code: string; name: I18nText; country: string | null }
export async function registries(s: Session): Promise<RegistryRef[]> {
  return rows<RegistryRef>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT code, name, country FROM registry.registry ORDER BY code`)));
}
function findRegistry(v: string, list: RegistryRef[]): string | null {
  const k = norm(v);
  if (!k) return null;
  const hit = list.find((r) => r.code.toLowerCase() === k || (r.country ?? "").toLowerCase() === k
    || Object.values(r.name ?? {}).some((n) => n && (norm(n) === k || norm(n).includes(k) && k.length >= 4)));
  if (hit) return hit.code;
  const names: Record<string, string> = { uae: "AE", emirates: "AE", "united arab emirates": "AE", "الإمارات": "AE", "الامارات": "AE", ksa: "SA", "saudi arabia": "SA", saudi: "SA", "السعودية": "SA" };
  const code = names[k];
  return code && list.some((r) => r.code === code) ? code : null;
}
const STAGE_WORDS: Record<string, IntakeStage> = {
  filed: "filed", filing: "filed", pending: "filed", applied: "filed", "under examination": "filed", examination: "filed", "مودع": "filed", "قيد الفحص": "filed",
  accepted: "accepted", acceptance: "accepted", "مقبول": "accepted", published: "published", publication: "published", "منشور": "published",
  "fee paid": "fee_paid", fee_paid: "fee_paid", registered: "registered", registration: "registered", "مسجل": "registered", "مسجلة": "registered",
  renewed: "renewed", renewal: "renewed", "مجدد": "renewed", "مجددة": "renewed",
};

export interface ParsedRow { data: IntakeData; errors: string[]; notes: Array<{ code: string; value: string; field: string }> }

/** One staged row → the intake data of a trademark, with what could not be read (errors) and what was set aside (notes). */
export function readRow(cells: string[], mapping: Record<string, ImportField | "">, regs: RegistryRef[]): ParsedRow {
  const get = (f: ImportField) => { const i = Object.keys(mapping).find((k) => mapping[k] === f); return i === undefined ? "" : (cells[Number(i)] ?? "").trim(); };
  const data: IntakeData = { manager: "self" };
  const errors: string[] = [];
  const notes: ParsedRow["notes"] = [];
  if (get("client")) data.client_name = get("client").replace(/\s+/g, " ").slice(0, 300);
  const reg = findRegistry(get("registry"), regs);
  if (reg) data.registry_code = reg; else errors.push(get("registry") ? "registryUnknown" : "registryMissing");
  if (get("mark_text_en")) data.mark_text_en = get("mark_text_en").slice(0, 300);
  if (get("mark_text_ar")) data.mark_text_ar = get("mark_text_ar").slice(0, 300);
  // a mark typed in Arabic under the single "mark" column belongs in the Arabic field
  if (data.mark_text_en && !data.mark_text_ar && /[؀-ۿ]/.test(data.mark_text_en) && !/[A-Za-z]/.test(data.mark_text_en)) { data.mark_text_ar = data.mark_text_en; delete data.mark_text_en; }
  const type = norm(get("mark_type"));
  data.mark_type = /device|logo|figur|شعار|رسم/.test(type) ? "device" : /combin|mixed|مركب/.test(type) ? "combined" : "word";
  const classes = [...new Set((get("classes").match(/\d+/g) ?? []).map(Number))];
  const good = classes.filter((c) => c >= 1 && c <= 45);
  if (good.length) data.classes = good.sort((a, b) => a - b);
  for (const c of classes.filter((x) => !(x >= 1 && x <= 45))) notes.push({ code: "classDropped", value: String(c), field: "classes" });
  if (get("goods")) data.goods = get("goods").slice(0, 4000);
  if (get("application_no")) data.application_no = get("application_no").slice(0, 60);
  if (get("registration_no")) data.registration_no = get("registration_no").slice(0, 60);
  for (const f of DATE_FIELDS) {
    const raw = get(f);
    if (!raw) continue;
    const iso = parseDate(raw);
    if (iso) (data as Record<string, unknown>)[f] = iso; else notes.push({ code: "dateUnread", value: raw.slice(0, 40), field: f });
  }
  // the stage: as given, otherwise read from what the row carries
  const given = STAGE_WORDS[norm(get("stage"))] ?? (INTAKE_STAGES as string[]).includes(norm(get("stage")).replace(" ", "_")) ? (STAGE_WORDS[norm(get("stage"))] ?? (norm(get("stage")).replace(" ", "_") as IntakeStage)) : undefined;
  data.stage = given ?? (data.renewal_date ? "renewed" : data.registration_no || data.registration_date ? "registered" : data.publication_date ? "published" : data.acceptance_date ? "accepted" : "filed");
  if (get("stage") && !given) notes.push({ code: "stageUnread", value: get("stage").slice(0, 40), field: "stage" });
  if (!data.mark_text_en && !data.mark_text_ar && !data.application_no && !data.registration_no) errors.push("nothingToIdentify");
  return { data, errors, notes };
}

// ---------------------------------------------------------------- batches
export interface ImportBatch {
  id: string; status: "staged" | "validated" | "committed" | "cancelled"; created_at: string; committed_at: string | null;
  summary: { file_name?: string; headers?: string[]; mapping?: Record<string, ImportField | "">; rows?: number; ready?: number; with_warnings?: number; unreadable?: number; duplicates?: number; clients?: number; new_clients?: number;
             loaded?: number; warnings?: number; timers?: number; overdue?: number; due_90?: number; failed?: number;
             load_started_at?: string; progress_at?: string; load_finished_at?: string };
}
export interface ImportRow { id: string; row_no: number; raw: { cells: string[]; data?: IntakeData; notes?: ParsedRow["notes"]; duplicate?: boolean; failed?: string; /** why, when the registry number was refused (migration 0111) */ failed_code?: "numberActive" | "numberMine" | "numberTaken" }; warnings: Warning[]; errors: string[]; record_id: string | null }

export async function listBatches(s: Session): Promise<ImportBatch[]> {
  return rows<ImportBatch>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT id, status, summary, created_at, committed_at FROM platform.import_batch WHERE status <> 'cancelled' ORDER BY created_at DESC LIMIT 20`)));
}
export async function getBatch(s: Session, id: string): Promise<{ batch: ImportBatch; rows: ImportRow[] } | null> {
  return withAccount(db(), ctx(s), async (tx) => {
    const b = rows<ImportBatch>(await tx.execute(sql`SELECT id, status, summary, created_at, committed_at FROM platform.import_batch WHERE id = ${id}::uuid`))[0];
    if (!b) return null;
    const r = rows<ImportRow>(await tx.execute(sql`SELECT id, row_no, raw, warnings, errors, record_id FROM platform.import_row WHERE batch_id = ${id}::uuid ORDER BY row_no`));
    return { batch: b, rows: r };
  });
}

/** Stages an uploaded file: the header row and every data row as text, nothing interpreted yet. Returns the batch id. */
export async function stageFile(s: Session, fileName: string, text: string): Promise<{ id: string } | { error: "empty" | "tooMany" | "noHeader" }> {
  const table = parseCsv(text);
  if (table.length < 2) return { error: table.length === 0 ? "empty" : "noHeader" };
  const [headers, ...data] = table as [string[], ...string[][]];
  if (data.length > MAX_IMPORT_ROWS) return { error: "tooMany" };
  const summary = { file_name: fileName.slice(0, 200), headers, mapping: autoMap(headers, fieldsFor(s)), rows: data.length };
  return withAccount(db(), ctx(s), async (tx) => {
    const b = rows<{ id: string }>(await tx.execute(sql`
      INSERT INTO platform.import_batch (account_id, user_id, status, summary) VALUES (${s.accountId}::uuid, ${s.userId}::uuid, 'staged', ${JSON.stringify(summary)}::jsonb) RETURNING id`))[0]!;
    // a thousand rows per statement
    for (let i = 0; i < data.length; i += 1000) {
      await tx.execute(sql`INSERT INTO platform.import_row (batch_id, row_no, raw)
                           SELECT ${b.id}::uuid, ${i}::int + o.n::int, jsonb_build_object('cells', o.cells)
                             FROM jsonb_array_elements(${JSON.stringify(data.slice(i, i + 1000))}::jsonb) WITH ORDINALITY o(cells, n)`);
    }
    return { id: String(b.id) };
  });
}

/** Applies the column mapping: reads and checks every row, and marks rows already in the portfolio or repeated in the file. */
export async function validateBatch(s: Session, id: string, mapping: Record<string, ImportField | "">): Promise<boolean> {
  const got = await getBatch(s, id);
  if (!got || (got.batch.status !== "staged" && got.batch.status !== "validated") || isLoading(got.batch)) return false;
  const allowed = fieldsFor(s);
  for (const k of Object.keys(mapping)) if (mapping[k] && !allowed.includes(mapping[k] as ImportField)) mapping[k] = "";
  const regs = await registries(s);
  const existing = new Set(rows<{ k: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT g.code || '|' || lower(x.no) AS k FROM core.record r JOIN registry.registry g ON g.id = r.registry_id
      CROSS JOIN LATERAL (VALUES (r.application_no), (r.registration_no)) x(no) WHERE x.no IS NOT NULL`))).map((x) => x.k));
  const rulesCache = new Map<string, Awaited<ReturnType<typeof profileRules>>>();
  const seen = new Set<string>();
  const counts = { ready: 0, with_warnings: 0, unreadable: 0, duplicates: 0, clients: 0, new_clients: 0 };
  const clientNames = new Set<string>();
  const out: Array<{ id: string; raw: ImportRow["raw"]; warnings: Warning[]; errors: string[] }> = [];
  for (const r of got.rows) {
    const p = readRow(r.raw.cells, mapping, regs);
    let warnings: Warning[] = [];
    let duplicate = false;
    if (p.errors.length === 0) {
      const code = p.data.registry_code!;
      if (!rulesCache.has(code)) rulesCache.set(code, await profileRules(code));
      warnings = runChecks(p.data, rulesCache.get(code) ?? null);
      const keys = [p.data.application_no, p.data.registration_no].filter(Boolean).map((n) => `${code}|${String(n).toLowerCase()}`);
      duplicate = keys.some((k) => existing.has(k) || seen.has(k));
      keys.forEach((k) => seen.add(k));
    }
    if (!p.errors.length && !duplicate && p.data.client_name) clientNames.add(p.data.client_name);
    if (p.errors.length) counts.unreadable++; else if (duplicate) counts.duplicates++; else { counts.ready++; if (warnings.length || p.notes.length) counts.with_warnings++; }
    out.push({ id: r.id, raw: { cells: r.raw.cells, data: p.data, notes: p.notes, duplicate }, warnings, errors: p.errors });
  }
  // the clients named in the rows that will load: how many names, and how many are not in the agency's list yet
  if (clientNames.size) {
    const c = rows<{ names: number; fresh: number }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
      SELECT count(DISTINCT k)::int AS names, count(DISTINCT k) FILTER (WHERE NOT EXISTS (SELECT 1 FROM core.client c WHERE c.name_key = k))::int AS fresh
        FROM (SELECT core.fn_client_key(n) AS k FROM jsonb_array_elements_text(${JSON.stringify([...clientNames])}::jsonb) n) x WHERE k <> ''`)))[0];
    counts.clients = c?.names ?? 0; counts.new_clients = c?.fresh ?? 0;
  }
  await withAccount(db(), ctx(s), async (tx) => {
    for (let i = 0; i < out.length; i += 500) {
      await tx.execute(sql`UPDATE platform.import_row r SET raw = x.raw, warnings = x.warnings, errors = x.errors
                             FROM jsonb_to_recordset(${JSON.stringify(out.slice(i, i + 500))}::jsonb) AS x(id uuid, raw jsonb, warnings jsonb, errors jsonb)
                            WHERE r.id = x.id AND r.batch_id = ${id}::uuid`);
    }
    await tx.execute(sql`UPDATE platform.import_batch SET status = 'validated', summary = summary || ${JSON.stringify({ mapping, ...counts })}::jsonb WHERE id = ${id}::uuid`);
  });
  return true;
}

/** Loading has started and its last sign of progress is recent; an older one means the server restarted and it can be continued. */
const STALE_MS = 2 * 60 * 1000;
export const isLoading = (b: ImportBatch) => b.status === "validated" && Boolean(b.summary.load_started_at);
export const isStalled = (b: ImportBatch) => isLoading(b) && Date.now() - new Date(b.summary.progress_at ?? b.summary.load_started_at!).getTime() > STALE_MS;

/**
 * Starts loading in the background and returns at once, so a file of thousands of rows does not hold the page
 * (Founder ruling 27 Nov 2026: up to 5,000 rows per file). Only one loading runs per import: a second start is
 * refused unless the first has shown no progress for two minutes (the server was restarted), in which case it
 * carries on from the rows not loaded yet.
 */
export async function startCommit(s: Session, id: string): Promise<boolean> {
  const stale = new Date(Date.now() - STALE_MS).toISOString();
  const now = new Date().toISOString();
  const got = rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    UPDATE platform.import_batch
       SET summary = summary || jsonb_build_object('load_started_at', COALESCE(summary ->> 'load_started_at', ${now}::text), 'progress_at', ${now}::text)
     WHERE id = ${id}::uuid AND status = 'validated'
       AND (summary ->> 'load_started_at' IS NULL OR COALESCE(summary ->> 'progress_at', summary ->> 'load_started_at') < ${stale}::text)
    RETURNING id`)));
  if (!got.length) return false;
  void commitBatch(s, id).catch((e) => console.error(JSON.stringify({ level: "error", at: "import.load", batch: id, message: (e as Error).message })));
  return true;
}

/**
 * Loads every readable, non-duplicate row as a trademark, each in its own transaction so one bad row does not
 * stop the rest, a few rows at a time, then writes the import summary (item 44): rows loaded, warnings kept,
 * clocks created, and how many dates are overdue or due within 90 days. A row is taken under a lock and skipped
 * when it is already loaded, so a continued loading never loads a row twice.
 */
async function commitBatch(s: Session, id: string): Promise<void> {
  const got = await getBatch(s, id);
  if (!got || got.batch.status !== "validated") return;
  const rulesCache = new Map<string, Promise<Awaited<ReturnType<typeof profileRules>>>>();
  const rulesFor = (code: string) => { if (!rulesCache.has(code)) rulesCache.set(code, profileRules(code)); return rulesCache.get(code)!; };
  const todo = got.rows.filter((r) => r.raw.data && !r.errors.length && !r.raw.duplicate && !r.record_id && !r.raw.failed);
  let done = 0;
  const one = async (r: ImportRow) => {
    const data = r.raw.data!;
    try {
      const w = runChecks(data, (await rulesFor(data.registry_code!)) ?? null);
      const markText: I18nText = {};
      if (data.mark_text_ar) markText.ar = data.mark_text_ar;
      if (data.mark_text_en) markText.en = data.mark_text_en;
      const familyName: I18nText = Object.keys(markText).length ? markText : { en: data.registration_no ?? data.application_no ?? "mark" };
      await withAccount(db(), ctx(s), async (tx) => {
        const mine = rows(await tx.execute(sql`SELECT 1 FROM platform.import_row WHERE id = ${r.id}::uuid AND record_id IS NULL FOR UPDATE SKIP LOCKED`));
        if (!mine.length) return;
        const rid = await insertLoadedRecord(tx, s, data, w, "bulk_import", "bulk_import", markText, familyName);
        await tx.execute(sql`UPDATE platform.import_row SET record_id = ${rid}::uuid, warnings = ${JSON.stringify(w)}::jsonb WHERE id = ${r.id}::uuid`);
      });
    } catch (e) {
      const message = (e as Error & { cause?: Error }).cause?.message ?? (e as Error).message;
      console.error(JSON.stringify({ level: "error", at: "import.row", batch: id, row: r.row_no, message }));
      await withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE platform.import_row SET raw = raw || ${JSON.stringify({ failed: message.slice(0, 200), ...(numberProblem(e) ? { failed_code: numberProblem(e) } : {}) })}::jsonb WHERE id = ${r.id}::uuid`));
    }
    if (++done % 20 === 0) {
      await withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE platform.import_batch SET summary = summary || ${JSON.stringify({ progress_at: new Date().toISOString() })}::jsonb WHERE id = ${id}::uuid AND status = 'validated'`));
    }
  };
  // a few rows at a time: each waits on the database, not on this process
  let next = 0;
  await Promise.all(Array.from({ length: LOAD_WORKERS }, async () => { while (next < todo.length) await one(todo[next++]!); }));

  await withAccount(db(), ctx(s), async (tx) => {
    const c = rows<{ loaded: number; failed: number; warnings: number }>(await tx.execute(sql`
      SELECT count(*) FILTER (WHERE record_id IS NOT NULL)::int AS loaded, count(*) FILTER (WHERE record_id IS NULL AND raw ? 'failed')::int AS failed,
             COALESCE(sum(jsonb_array_length(warnings)) FILTER (WHERE record_id IS NOT NULL), 0)::int AS warnings
        FROM platform.import_row WHERE batch_id = ${id}::uuid`))[0];
    const t = rows<{ timers: number; overdue: number; due_90: number }>(await tx.execute(sql`
      SELECT count(*)::int AS timers, count(*) FILTER (WHERE t.due_date < current_date)::int AS overdue,
             count(*) FILTER (WHERE t.due_date >= current_date AND t.due_date <= current_date + 90)::int AS due_90
        FROM core.timer t JOIN platform.import_row ir ON ir.record_id = t.record_id
       WHERE ir.batch_id = ${id}::uuid AND t.state = 'open' AND t.family = 'statutory'`))[0];
    const summary = { loaded: c?.loaded ?? 0, warnings: c?.warnings ?? 0, failed: c?.failed ?? 0, timers: t?.timers ?? 0, overdue: t?.overdue ?? 0, due_90: t?.due_90 ?? 0,
                      load_finished_at: new Date().toISOString() };
    await tx.execute(sql`UPDATE platform.import_batch SET status = 'committed', committed_at = now(), summary = summary || ${JSON.stringify(summary)}::jsonb WHERE id = ${id}::uuid AND status = 'validated'`);
  });
}

export const cancelBatch = (s: Session, id: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE platform.import_batch SET status = 'cancelled' WHERE id = ${id}::uuid AND status IN ('staged', 'validated') AND summary ->> 'load_started_at' IS NULL`));

/** The template: one header row in Meesam's own column names and one example row, as CSV that opens in Excel (UTF-8 with BOM). */
export function templateCsv(withClient = false): string {
  const head = ["Registry", "Mark (English)", "Mark (Arabic)", "Mark type", "Classes", "Goods and services", "Stage", "Application number", "Filing date",
    "Acceptance date", "Publication date", "Registration number", "Registration date", "Expiry date", "Renewal date"];
  const example = ["AE", "Example", "مثال", "word", "29, 30", "", "registered", "123456", "2021-03-15", "", "2021-06-01", "123456", "2021-09-20", "2031-03-15", ""];
  if (withClient) { head.unshift("Client"); example.unshift("Example Trading L.L.C."); }
  const q = (v: string) => (/[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  return `﻿${head.map(q).join(",")}\r\n${example.map(q).join(",")}\r\n`;
}
