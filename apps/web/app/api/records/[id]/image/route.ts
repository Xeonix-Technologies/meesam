import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { isLocale } from "@meesam/i18n";
import { db } from "@/lib/db";
import { go, requireVerified } from "@/lib/guard";
import { addDocument, recordNumbers, setMarkImage } from "@/lib/records";
import { storeUpload } from "@/lib/upload";

export const runtime = "nodejs";

const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/webp"]);
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

/**
 * Upload or replace the mark's image (Mark and classes tab). The file is a vault document and the
 * record points at it; the previous image stays in the vault as history (item 43: nothing is deleted).
 * RULING NEEDED: item 43 lists 14 document type codes and none for the mark representation itself;
 * until ruled, the image is filed as OTH. A fifteenth code (e.g. IMG) would make vault listings clearer.
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const file = form.get("file");
  if (!(file instanceof File) || !IMAGE_TYPES.has(file.type)) return go(req, back, { error: "imageType", tab: "mark" });
  if (file.size === 0 || file.size > MAX_IMAGE_BYTES) return go(req, back, { error: "imageSize", tab: "mark" });
  const numbers = await recordNumbers(auth.session, id);
  if (!numbers) return go(req, `/${locale}/records`);
  const ctx = { accountId: auth.session.accountId, userId: auth.session.userId };
  const existing = (await withAccount(db(), ctx, (tx) => tx.execute(sql`SELECT object_key FROM core.document WHERE record_id = ${id}::uuid`))) as unknown as Array<{ object_key: string }>;
  const taken = new Set(existing.map((e) => e.object_key));
  const registry = (await withAccount(db(), ctx, (tx) =>
    tx.execute(sql`SELECT g.code FROM core.record r JOIN registry.registry g ON g.id = r.registry_id WHERE r.id = ${id}::uuid`))) as unknown as Array<{ code: string }>;
  try {
    const stored = await storeUpload(file, "OTH", registry[0]?.code ?? "XX", numbers.registration_no, numbers.application_no, taken);
    if ("error" in stored) return go(req, back, { error: stored.error, tab: "mark" });
    const docId = await addDocument(auth.session, id, stored);
    await setMarkImage(auth.session, id, docId);
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "record.image", message: (err as Error).message }));
    return go(req, back, { error: "vault", tab: "mark" });
  }
  return go(req, back, { tab: "mark", saved: "1" });
}
