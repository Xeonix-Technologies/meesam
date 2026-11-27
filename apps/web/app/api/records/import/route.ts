import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { MAX_IMPORT_BYTES, MAX_IMPORT_ROWS, stageFile } from "@/lib/importer";
import { sheetCsv } from "@/lib/xlsx";

export const runtime = "nodejs";

/** Bulk import, step 1: the spreadsheet (an Excel workbook, or a sheet saved as CSV) is staged row by row; nothing is loaded yet. */
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
  // the old .xls format is not read; a workbook (.xlsx) is, its first sheet
  if (/\.xls$/i.test(file.name)) return go(req, back, { error: "excel" });
  try {
    const bytes = Buffer.from(await file.arrayBuffer());
    if (/\.xlsx$/i.test(file.name) || (bytes[0] === 0x50 && bytes[1] === 0x4b)) {
      let csv: string;
      // the header row, the rows allowed, and one more so that a longer sheet is refused as too long, not cut short
      try { csv = sheetCsv(bytes, MAX_IMPORT_ROWS + 2); } catch { return go(req, back, { error: "workbook" }); }
      const r = await stageFile(auth.session, file.name, csv);
      if ("error" in r) return go(req, back, { error: r.error });
      return go(req, `${back}/${r.id}`);
    }
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
