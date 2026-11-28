import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { db } from "./db";
import { extractionConfigured, readDocument } from "./extract";
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
      await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
        SELECT core.fn_certificate_reading_set(${d.id}::uuid, ${date}::date, ${filing}::date, ${applicationNo}::text, ${registrationNo}::text, ${f?.confidence ?? 0}::numeric, ${f?.source ?? null}::text, ${ex?.model ?? null}::text,
                                               ${ex?.usage?.input_tokens ?? null}::int, ${ex?.usage?.output_tokens ?? null}::int, ${registeredOn}::date)`));
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
  try {
    const n = ((await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
      SELECT n.certificate_state, n.number_agrees, c.filing_date::text, c.registration_date::text, c.expiry_date::text
        FROM core.fn_activation_needs(${recordId}::uuid) n, core.fn_certificate_dates(${recordId}::uuid) c`))) as unknown as Array<{ certificate_state: string | null; number_agrees: boolean | null;
          filing_date: string | null; registration_date: string | null; expiry_date: string | null }>)[0];
    if (!n || n.certificate_state !== "mismatch" || n.number_agrees !== true || !n.expiry_date) return false;
    await updateCertificate(s, recordId, { filing_date: n.filing_date, registration_date: n.registration_date, expiry_date: n.expiry_date });
    return true;
  } catch (e) {
    // a user who may not correct the record (a Viewer, say) leaves the dates as they are; the note still shows the difference
    console.error(JSON.stringify({ level: "warn", at: "certificate.fill", record: recordId, message: (e as Error).message }));
    return false;
  }
}
