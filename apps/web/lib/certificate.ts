import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { db } from "./db";
import { checkOnDocument, extractionConfigured, readDocument } from "./extract";
import { updateCertificate, type Upload } from "./records";
import type { Session } from "./session";

/**
 * Meesam reads the certificate (Founder ruling 28 Nov 2026; migration 0106). Each certificate on a record that has
 * not been read yet is read once by the document reader; the expiry date it found, or the fact that none could be
 * made out, is kept by the database, which then decides whether the mark may be activated: the certificate's date
 * and the record's must agree, because the fee is calculated from it. A reading never changes the record.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const DATE = /^\d{4}-\d{2}-\d{2}$/;
/** Below this the reader's own confidence in the date is too low and a clearer copy is asked for. Configuration, 0.8 where unset. */
const minConfidence = () => { const v = Number(process.env.CERT_READ_MIN_CONFIDENCE); return v > 0 && v <= 1 ? v : 0.8; };
/** Certificates read in one go: each reading takes some seconds while the page waits. */
const MAX_AT_ONCE = 2;

export interface CertificateRun { configured: boolean; read: number; unclear: number; failed: number; left: number; /** the record's dates were taken from the certificate */ filled: boolean }

export async function readCertificates(s: Session, recordId: string): Promise<CertificateRun> {
  const out: CertificateRun = { configured: extractionConfigured(), read: 0, unclear: 0, failed: 0, left: 0, filled: false };

  // the record's certificates not read yet, newest first (row-level security: only a record this account sees)
  const todo = (await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT d.id, d.object_key, d.content_type, d.doc_type
      FROM core.document d
     WHERE d.record_id = ${recordId}::uuid AND d.removed_at IS NULL AND d.doc_type IN ('ORC', 'REN')
       AND NOT EXISTS (SELECT 1 FROM core.certificate_reading c WHERE c.document_id = d.id)
     ORDER BY d.created_at DESC`))) as unknown as Array<{ id: string; object_key: string; content_type: string | null; doc_type: string }>;
  if (!out.configured) { out.left = todo.length; return out; }
  out.left = Math.max(0, todo.length - MAX_AT_ONCE);
  for (const d of todo.slice(0, MAX_AT_ONCE)) {
    let step = "reader";
    try {
      // the reader is asked twice when it is busy or does not answer; a second failure leaves the certificate unread
      let ex: Awaited<ReturnType<typeof readDocument>>;
      try { ex = await readDocument({ object_key: d.object_key, content_type: d.content_type ?? "" } as Upload); }
      catch (first) {
        console.error(JSON.stringify({ level: "warn", at: "certificate.read", step, attempt: 1, record: recordId, document: d.id, message: (first as Error).message }));
        await new Promise((r) => setTimeout(r, 3000));
        ex = await readDocument({ object_key: d.object_key, content_type: d.content_type ?? "" } as Upload);
      }
      step = "store";
      // a file type the reader cannot open (a word-processor file, say) is asked for again as a scan or PDF
      const f = ex?.fields.expiry_date;
      const date = f && typeof f.value === "string" && DATE.test(f.value) && f.confidence >= minConfidence() ? f.value : null;
      // the filing date printed on the certificate is matched too (Founder ruling 28 Nov 2026); one the reader is not sure of is left out
      const g = ex?.fields.filing_date;
      const filing = g && typeof g.value === "string" && DATE.test(g.value) && g.confidence >= minConfidence() ? g.value : null;
      // the numbers printed on the certificate tie it to one record (Founder ruling 28 Nov 2026)
      const num = (x: typeof f) => (x && (typeof x.value === "string" || typeof x.value === "number") && x.confidence >= minConfidence() ? String(x.value).trim().slice(0, 60) || null : null);
      const applicationNo = num(ex?.fields.application_no);
      const registrationNo = num(ex?.fields.registration_no);
      // the registration date is that of a registration certificate; a renewal certificate's own date is not it
      const rd = ex?.fields.registration_date;
      const registeredOn = d.doc_type === "ORC" && rd && typeof rd.value === "string" && DATE.test(rd.value) && rd.confidence >= minConfidence() ? rd.value : null;
      // the issuing office and the classes tie the certificate to this registry and this class (Founder ruling 28 Nov 2026):
      // the same number exists at several offices, and one mark has a certificate for each class
      const oc = ex?.fields.registry_code;
      const office = oc && typeof oc.value === "string" && /^[A-Za-z]{2}$/.test(oc.value.trim()) && oc.confidence >= minConfidence() ? oc.value.trim().toUpperCase() : null;
      const cl = ex?.fields.classes;
      const classNos = cl && cl.confidence >= minConfidence() ? (Array.isArray(cl.value) ? cl.value : [cl.value]).map((v) => Number(v)).filter((v) => Number.isInteger(v) && v >= 1 && v <= 45) : [];
      const classes = classNos.length ? `{${[...new Set(classNos)].join(",")}}` : null;
      // the mark's wording is compared as a note only, never a bar
      const name = (x: typeof f) => (x && typeof x.value === "string" && x.confidence >= minConfidence() ? x.value.trim().slice(0, 300) || null : null);
      await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
        SELECT core.fn_certificate_reading_set(${d.id}::uuid, ${date}::date, ${filing}::date, ${applicationNo}::text, ${registrationNo}::text, ${f?.confidence ?? 0}::numeric, ${f?.source ?? null}::text, ${ex?.model ?? null}::text,
                                               ${ex?.usage?.input_tokens ?? null}::int, ${ex?.usage?.output_tokens ?? null}::int, ${registeredOn}::date,
                                               ${office}::text, ${classes}::smallint[], ${name(ex?.fields.mark_text_ar)}::text, ${name(ex?.fields.mark_text_en)}::text)`));
      if (date) out.read++; else out.unclear++;
    } catch (e) {
      // the reader did not answer: the certificate stays unread and can be read again
      const err = e as Error & { cause?: { message?: string } };
      console.error(JSON.stringify({ level: "error", at: "certificate.read", step, record: recordId, document: d.id, type: d.content_type, message: err.cause?.message ?? err.message }));
      out.failed++;
    }
  }
  if (out.read) out.filled = await fillFromCertificate(s, recordId);
  return out;
}

/**
 * When the certificate's number is this record's, the record's filing, registration and expiry dates are taken from
 * the certificate (Founder, 28 Nov 2026: "the Certificate information is not updated from the document read").
 * Called when a certificate has just been read, and when the account has just corrected the record's number so
 * that it agrees. The number itself is never changed by a reading: a certificate of another mark must not turn
 * this record into that mark. The change is the signed-in user's, audited and notified like any correction on the
 * Certificate tab. Returns whether anything was filled.
 */
export async function fillFromCertificate(s: Session, recordId: string): Promise<boolean> {
  // a mark that is not active takes the mark's wording and its classes from its own certificate first (migration 0113)
  let applied = false;
  try {
    applied = ((await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_certificate_apply(${recordId}::uuid) AS changed`))) as unknown as Array<{ changed: boolean }>)[0]?.changed === true;
  } catch (e) {
    console.error(JSON.stringify({ level: "warn", at: "certificate.apply", record: recordId, message: ((e as Error & { cause?: Error }).cause ?? (e as Error)).message }));
  }
  try {
    const n = ((await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
      SELECT n.certificate_state, n.number_agrees, n.office_agrees, n.classes_agree, c.filing_date::text, c.registration_date::text, c.expiry_date::text
        FROM core.fn_activation_needs(${recordId}::uuid) n, core.fn_certificate_dates(${recordId}::uuid) c`))) as unknown as Array<{ certificate_state: string | null; number_agrees: boolean | null; office_agrees: boolean | null; classes_agree: boolean | null;
          filing_date: string | null; registration_date: string | null; expiry_date: string | null }>)[0];
    // a certificate of another office or another class is not this record's: it fills nothing
    if (!n || n.certificate_state !== "mismatch" || n.number_agrees !== true || n.office_agrees === false || n.classes_agree === false || !n.expiry_date) return applied;
    await updateCertificate(s, recordId, { filing_date: n.filing_date, registration_date: n.registration_date, expiry_date: n.expiry_date });
    return true;
  } catch (e) {
    // a user who may not correct the record (a Viewer, say) leaves the dates as they are; the note still shows the difference
    console.error(JSON.stringify({ level: "warn", at: "certificate.fill", record: recordId, message: (e as Error).message }));
    return applied;
  }
}

/** The tick (migration 0113): what the certificate says is first carried to the record, then the reading in use is confirmed. */
export async function confirmCertificate(s: Session, recordId: string): Promise<void> {
  await fillFromCertificate(s, recordId);
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_certificate_confirm(${recordId}::uuid)`));
}

export const CORRECTION_FIELDS = ["mark_text_en", "mark_text_ar", "classes", "filing_date", "registration_date", "expiry_date"] as const;
export type CorrectionField = (typeof CORRECTION_FIELDS)[number];
const FIELD_WORDS: Record<CorrectionField, string> = { mark_text_en: "mark's wording in Latin script", mark_text_ar: "mark's wording in Arabic script", classes: "Nice class or classes (numbers)",
  filing_date: "filing (application) date, as YYYY-MM-DD", registration_date: "registration date, as YYYY-MM-DD", expiry_date: "expiry date (end of protection), as YYYY-MM-DD" };

/**
 * A correction of one field (Founder ruling 28 Nov 2026): the reader is asked whether the certificate bears the value
 * out, the database looks at what the registry published, and the correction is accepted or held. Accepted: the
 * record follows at once. Held: activation waits, and Meesam's administrators and the person who entered it are told.
 */
export async function correctCertificate(s: Session, recordId: string, field: CorrectionField, value: string): Promise<{ state: "accepted" | "held"; alert: Array<{ email: string; name: string; locale: string; staff: boolean }> }> {
  const id = ((await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_certificate_correction_open(${recordId}::uuid, ${field}::text, ${value}::text) AS id`))) as unknown as Array<{ id: string }>)[0]!.id;
  const doc = ((await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT d.object_key, d.content_type, k.corrected_value FROM core.certificate_correction k JOIN core.document d ON d.id = k.document_id WHERE k.id = ${id}::uuid`))) as unknown as Array<{ object_key: string; content_type: string | null; corrected_value: string }>)[0];
  // a reader that does not answer leaves the question open: the correction is held for a person to settle
  let check: Awaited<ReturnType<typeof checkOnDocument>> = null;
  try { if (doc) check = await checkOnDocument({ object_key: doc.object_key, content_type: doc.content_type ?? "" } as Upload, FIELD_WORDS[field], doc.corrected_value); }
  catch (e) { console.error(JSON.stringify({ level: "error", at: "certificate.correction", record: recordId, message: (e as Error).message })); }
  const state = ((await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT core.fn_certificate_correction_check(${id}::uuid, ${check?.verdict ?? "unclear"}::text, ${check?.passage ?? null}::text, ${check?.model ?? null}::text,
                                                ${check?.usage.input_tokens ?? null}::int, ${check?.usage.output_tokens ?? null}::int) AS state`))) as unknown as Array<{ state: "accepted" | "held" }>)[0]!.state;
  if (state === "accepted") { await fillFromCertificate(s, recordId); return { state, alert: [] }; }
  const alert = (await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT email, name, locale, staff FROM core.fn_certificate_correction_alert(${id}::uuid)`))) as unknown as Array<{ email: string; name: string; locale: string; staff: boolean }>;
  return { state, alert: [...alert] };
}

export async function withdrawCorrection(s: Session, correctionId: string): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_certificate_correction_withdraw(${correctionId}::uuid)`));
}
