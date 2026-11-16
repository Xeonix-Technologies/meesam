import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { isLocale } from "@meesam/i18n";
import { db } from "@/lib/db";
import { go, requireVerified } from "@/lib/guard";
import { addDocument, recordNumbers } from "@/lib/records";
import { storeUpload } from "@/lib/upload";

export const runtime = "nodejs";

/** Upload a document to a record's vault folder (Documents tab). */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const file = form.get("file");
  const docType = String(form.get("doc_type") ?? "");
  const validUntilRaw = String(form.get("valid_until") ?? "");
  const validUntil = /^\d{4}-\d{2}-\d{2}$/.test(validUntilRaw) ? validUntilRaw : null;
  if (!(file instanceof File)) return go(req, back, { error: "fileType", tab: "documents" });
  const numbers = await recordNumbers(auth.session, id);
  if (!numbers) return go(req, `/${locale}/records`);
  const taken = new Set<string>();
  const existing = (await withAccount(db(), { accountId: auth.session.accountId, userId: auth.session.userId }, (tx) =>
    tx.execute(sql`SELECT object_key FROM core.document WHERE record_id = ${id}::uuid`))) as unknown as Array<{ object_key: string }>;
  for (const e of existing) taken.add(e.object_key);
  const registry = (await withAccount(db(), { accountId: auth.session.accountId, userId: auth.session.userId }, (tx) =>
    tx.execute(sql`SELECT g.code FROM core.record r JOIN registry.registry g ON g.id = r.registry_id WHERE r.id = ${id}::uuid`))) as unknown as Array<{ code: string }>;
  try {
    const stored = await storeUpload(file, docType, registry[0]?.code ?? "XX", numbers.registration_no, numbers.application_no, taken);
    if ("error" in stored) return go(req, back, { error: stored.error, tab: "documents" });
    await addDocument(auth.session, id, { ...stored, valid_until: validUntil });
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "record.document", message: (err as Error).message }));
    return go(req, back, { error: "vault", tab: "documents" });
  }
  return go(req, back, { tab: "documents", saved: "1" });
}
