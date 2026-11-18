import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import { copyObject, deleteObject, vaultConfig, vaultKey } from "./s3";
import type { Session } from "./session";
import type { Draft } from "./records";

/**
 * Filing request (System Description Section 6): prepared in Meesam, filed with the registry outside
 * Meesam by the owner (where the registry allows) or by an agency, then recorded as Filed.
 * Meesam does not file, sign, pay, advise, show fees or search the register (Section 6, Ruled).
 */
export interface FilingData {
  // 1 applicant
  applicant_name_ar?: string; applicant_name_en?: string; legal_form?: string; nationality?: string;
  address?: string; contact_email?: string; contact_phone?: string;
  // 2 registry and who files
  registry_code?: string; route?: "self" | "agency"; agency_account_id?: string; agency_named?: string;
  // 3 mark
  mark_type?: "word" | "device" | "combined"; mark_text_ar?: string; mark_text_en?: string;
  transliteration?: string; translation?: string; colour_claim?: string; description?: string;
  // 4 classes and goods
  classes?: number[]; goods?: Record<string, string>; headings?: number[];
  // 5 priority
  priority_claimed?: boolean; priority_country?: string; priority_number?: string; priority_date?: string;
  // 6 declarations
  declaration_accuracy?: boolean;
}
export const FILING_STEPS = 7;

const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

/** The applicant block is pre-filled from the owner account (Section 6, group 1). */
export async function applicantDefaults(s: Session): Promise<Partial<FilingData>> {
  const a = rows<{ name: I18nText; country: string; contact: Record<string, string> | null; email: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT a.name, a.country, a.contact, u.email FROM core.account a JOIN core.app_user u ON u.account_id = a.id WHERE a.id = ${s.accountId}::uuid AND u.id = ${s.userId}::uuid`)))[0];
  if (!a) return {};
  return { applicant_name_ar: a.name.ar, applicant_name_en: a.name.en, nationality: a.country, address: a.contact?.address, contact_email: a.email, contact_phone: a.contact?.mobile ?? a.contact?.phone };
}

export interface FilingIssue { field: string; code: string }
/** Advisory checks before acceptance: they warn and never block (Section 4.7 applies to the filing request too). */
export function filingChecks(d: FilingData, today = new Date()): FilingIssue[] {
  const w: FilingIssue[] = [];
  if (!d.applicant_name_ar && !d.applicant_name_en) w.push({ field: "applicant_name_en", code: "missing" });
  if (!d.address) w.push({ field: "address", code: "missing" });
  if (d.mark_type !== "device" && !d.mark_text_ar && !d.mark_text_en) w.push({ field: "mark_text_en", code: "missing" });
  if (!d.classes?.length) w.push({ field: "classes", code: "missing" });
  for (const c of d.classes ?? []) if (!d.headings?.includes(c) && !(d.goods?.[String(c)] ?? "").trim()) w.push({ field: `goods_${c}`, code: "goodsMissing" });
  if (d.priority_claimed) {
    if (!d.priority_country || !d.priority_number || !d.priority_date) w.push({ field: "priority_date", code: "priorityIncomplete" });
    else {
      const p = new Date(`${d.priority_date}T00:00:00Z`);
      const months = (today.getUTCFullYear() - p.getUTCFullYear()) * 12 + today.getUTCMonth() - p.getUTCMonth() + (today.getUTCDate() > p.getUTCDate() ? 1 : 0);
      if (p > today) w.push({ field: "priority_date", code: "future" });
      else if (months > 6) w.push({ field: "priority_date", code: "priorityOld" });
    }
  }
  return w;
}

/** Accepting the request creates the record at stage 1 (pre-filing); it becomes Filed when the application number and date are recorded. */
export async function commitFiling(s: Session, draft: Draft, confirmations: Record<string, string>): Promise<string> {
  const d = draft.data as unknown as FilingData;
  if (!d.registry_code || !d.mark_type) throw new Error("filing draft incomplete");
  const mark: Record<string, string> = {};
  if (d.mark_text_ar) mark.ar = d.mark_text_ar;
  if (d.mark_text_en) mark.en = d.mark_text_en;
  const name = Object.keys(mark).length ? mark : { en: "(device mark)" };
  const request = {
    applicant: { name_ar: d.applicant_name_ar ?? null, name_en: d.applicant_name_en ?? null, legal_form: d.legal_form ?? null, nationality: d.nationality ?? null, address: d.address ?? null, email: d.contact_email ?? null, phone: d.contact_phone ?? null },
    route: { who: d.route ?? "self", agency_account_id: d.agency_account_id ?? null, agency_named: d.agency_named ?? null },
    mark: { transliteration: d.transliteration ?? null, translation: d.translation ?? null, colour_claim: d.colour_claim ?? null, description: d.description ?? null },
    priority: d.priority_claimed ? { country: d.priority_country ?? null, number: d.priority_number ?? null, date: d.priority_date ?? null } : null,
    declarations: { accuracy: Boolean(d.declaration_accuracy) },
    checks: filingChecks(d).map((w) => ({ ...w, confirmed_note: confirmations[w.field] ?? null })),
    accepted_at: new Date().toISOString(), accepted_by_user_id: s.userId,
  };
  const renamed: string[] = [];
  const recordId = await withAccount(db(), ctx(s), async (tx) => {
    const reg = rows<{ id: string }>(await tx.execute(sql`SELECT id FROM registry.registry WHERE code = ${d.registry_code}`))[0];
    if (!reg) throw new Error("unknown registry");
    const fam = rows<{ id: string }>(await tx.execute(sql`INSERT INTO core.mark_family (owner_account_id, name, mark_type) VALUES (${s.accountId}::uuid, ${JSON.stringify(name)}::jsonb, ${d.mark_type}::core.mark_type) RETURNING id`))[0]!;
    const rec = rows<{ id: string }>(await tx.execute(sql`
      INSERT INTO core.record (mark_family_id, registry_id, mark_text, entry_mode, paid_state, filing_request, priority_claimed, agent_of_record_account_id)
      VALUES (${fam.id}::uuid, ${reg.id}::uuid, ${Object.keys(mark).length ? JSON.stringify(mark) : null}::jsonb, 'new_filing', 'free_new_pending', ${JSON.stringify(request)}::jsonb, ${Boolean(d.priority_claimed)},
              ${d.route === "agency" && d.agency_account_id ? d.agency_account_id : null}::uuid)
      RETURNING id`))[0]!;
    for (const n of d.classes ?? []) {
      const goods = d.headings?.includes(n) ? "" : (d.goods?.[String(n)] ?? "").trim();
      const terms = goods ? JSON.stringify([/[؀-ۿ]/.test(goods) ? { ar: goods } : { en: goods }]) : null;
      await tx.execute(sql`INSERT INTO core.record_class (record_id, nice_class_id, terms) SELECT ${rec.id}::uuid, id, ${terms}::jsonb FROM registry.nice_class WHERE number = ${n} ON CONFLICT DO NOTHING`);
    }
    await tx.execute(sql`INSERT INTO core.record_registry_scope (record_id, registry_id, kind) VALUES (${rec.id}::uuid, ${reg.id}::uuid, 'filed')`);
    const taken = new Set<string>();
    let markImageKey: string | null = null;
    for (const u of draft.uploads) {
      const ext = u.object_key.split(".").pop() ?? "bin";
      // no number exists before filing: the draft id stands in until the application number is recorded
      let file = vaultKey(null, `REQ${draft.id.slice(0, 8)}`, new Date(u.uploaded_at), u.doc_type, ext);
      let key = `${d.registry_code}/${file}`;
      for (let n = 2; taken.has(key); n++) { file = file.replace(/\.([a-z0-9]+)$/, `_${n}.$1`); key = `${d.registry_code}/${file}`; }
      taken.add(key);
      if (key !== u.object_key) { await copyObject(vaultConfig(), u.object_key, key); renamed.push(u.object_key); }
      const doc = rows<{ id: string }>(await tx.execute(sql`
        INSERT INTO core.document (record_id, doc_type, object_key, file_name, content_type, size_bytes, sha256, uploaded_by_user_id, uploaded_by_account_id)
        VALUES (${rec.id}::uuid, ${u.doc_type}, ${key}, ${u.file_name}, ${u.content_type}, ${u.size}, decode(${u.sha256}, 'hex'), ${s.userId}::uuid, ${s.accountId}::uuid) RETURNING id`))[0]!;
      if (!markImageKey && (u as { purpose?: string }).purpose === "mark_image") { markImageKey = doc.id; }
    }
    if (markImageKey) await tx.execute(sql`UPDATE core.record SET mark_image_doc_id = ${markImageKey}::uuid WHERE id = ${rec.id}::uuid`);
    await tx.execute(sql`UPDATE core.intake_draft SET status = 'committed', record_id = ${rec.id}::uuid WHERE id = ${draft.id}::uuid`);
    return rec.id;
  });
  for (const k of renamed) { try { await deleteObject(vaultConfig(), k); } catch { /* the draft copy is swept later */ } }
  return recordId;
}
