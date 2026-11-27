import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { cancelBatch, fieldsFor, startCommit, validateBatch, type ImportField } from "@/lib/importer";

export const runtime = "nodejs";
export const maxDuration = 300;

/** Bulk import, steps 2 and 3: apply the column mapping and check the rows; then load them. */
export async function POST(req: Request, { params }: { params: Promise<{ batchId: string }> }) {
  const { batchId } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const list = `/${locale}/records/import`;
  if (!/^[0-9a-f-]{36}$/.test(batchId)) return go(req, list);
  const back = `${list}/${batchId}`;
  const action = String(form.get("action") ?? "");
  const fields: readonly string[] = fieldsFor(auth.session);
  try {
    if (action === "map") {
      const mapping: Record<string, ImportField | ""> = {};
      const used = new Set<string>();
      for (const [k, v] of form.entries()) {
        const m = /^col_(\d+)$/.exec(k);
        if (!m) continue;
        const f = String(v);
        // a field can be fed by one column only; a second column mapped to it is left unmapped
        mapping[m[1]!] = fields.includes(f) && !used.has(f) ? (f as ImportField) : "";
        if (mapping[m[1]!]) used.add(f);
      }
      if (!used.has("registry")) return go(req, back, { error: "needRegistry" });
      return (await validateBatch(auth.session, batchId, mapping)) ? go(req, back) : go(req, back, { error: "generic" });
    }
    if (action === "remap") return go(req, back, { remap: "1" });
    // loading runs in the background; the page shows how far it is. A second start while one runs just returns to the page.
    if (action === "commit") { await startCommit(auth.session, batchId); return go(req, back); }
    if (action === "cancel") { await cancelBatch(auth.session, batchId); return go(req, list, { saved: "cancelled" }); }
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "import", action, message: (e as Error).message }));
    return go(req, back, { error: "generic" });
  }
  return go(req, back);
}
