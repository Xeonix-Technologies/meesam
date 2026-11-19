import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { MAX_IMPORT_BYTES, stageFile } from "@/lib/importer";

export const runtime = "nodejs";

/** Bulk import, step 1: the spreadsheet (saved as CSV) is staged row by row; nothing is loaded yet. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/import`;
  const file = form.get("file");
  if (!(file instanceof File) || file.size === 0) return go(req, back, { error: "noFile" });
  if (file.size > MAX_IMPORT_BYTES) return go(req, back, { error: "tooBig" });
  if (/\.xlsx?$/i.test(file.name)) return go(req, back, { error: "excel" });
  try {
    const bytes = Buffer.from(await file.arrayBuffer());
    // a file saved as "Unicode text" by a spreadsheet program is UTF-16; everything else is read as UTF-8
    const text = bytes[0] === 0xff && bytes[1] === 0xfe ? bytes.toString("utf16le") : bytes.toString("utf8");
    if (text.includes("\u0000")) return go(req, back, { error: "notCsv" });
    const r = await stageFile(auth.session, file.name, text);
    if ("error" in r) return go(req, back, { error: r.error });
    return go(req, `${back}/${r.id}`);
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "import.stage", message: (e as Error).message }));
    return go(req, back, { error: "generic" });
  }
}
