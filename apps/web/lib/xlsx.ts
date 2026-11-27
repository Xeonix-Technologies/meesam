import { inflateRawSync } from "node:zlib";

/**
 * Reading an Excel workbook (.xlsx) for the bulk import, without a spreadsheet library: the first sheet becomes
 * rows of text, exactly what a "save as CSV" would have given. A workbook is a zip of XML files; this reads the
 * zip's index, inflates the few files needed and takes the cells' values. Dates are stored by Excel as day
 * numbers with a date format; they are written out as YYYY-MM-DD. Formulas give their last calculated value.
 * Not read: old .xls files, protected (encrypted) workbooks, anything beyond the first sheet.
 */
const MAX_FILE = 64 * 1024 * 1024;   // what one inner file may inflate to

function unzip(buf: Buffer): Map<string, () => Buffer> {
  // end of central directory: the last "PK\x05\x06" in the file
  let eocd = -1;
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65535); i--) if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error("not a workbook");
  const count = buf.readUInt16LE(eocd + 10);
  let at = buf.readUInt32LE(eocd + 16);
  const files = new Map<string, () => Buffer>();
  for (let n = 0; n < count; n++) {
    if (at + 46 > buf.length || buf.readUInt32LE(at) !== 0x02014b50) throw new Error("not a workbook");
    const method = buf.readUInt16LE(at + 10), csize = buf.readUInt32LE(at + 20), usize = buf.readUInt32LE(at + 24);
    const nameLen = buf.readUInt16LE(at + 28), extraLen = buf.readUInt16LE(at + 30), commentLen = buf.readUInt16LE(at + 32), local = buf.readUInt32LE(at + 42);
    const name = buf.toString("utf8", at + 46, at + 46 + nameLen);
    files.set(name, () => {
      if (usize > MAX_FILE) throw new Error("the workbook is too large");
      if (buf.readUInt32LE(local) !== 0x04034b50) throw new Error("not a workbook");
      const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
      const data = buf.subarray(start, start + csize);
      if (method === 0) return Buffer.from(data);
      if (method !== 8) throw new Error("the workbook uses a compression this reader does not know");
      return inflateRawSync(data, { maxOutputLength: MAX_FILE });
    });
    at += 46 + nameLen + extraLen + commentLen;
  }
  return files;
}

const unescape = (s: string) => s.replace(/&(lt|gt|amp|quot|apos|#x?[0-9a-fA-F]+);/g, (_, e: string) =>
  e === "lt" ? "<" : e === "gt" ? ">" : e === "amp" ? "&" : e === "quot" ? '"' : e === "apos" ? "'" : String.fromCodePoint(e[1] === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)));
/** The text of a string item: every <t> inside it, leaving out phonetic guides (<rPh>). */
const textOf = (xml: string) => [...xml.replace(/<rPh\b[\s\S]*?<\/rPh>/g, "").matchAll(/<t\b[^>]*>([\s\S]*?)<\/t>/g)].map((m) => unescape(m[1]!)).join("");
const attr = (tag: string, name: string) => new RegExp(`\\b${name}="([^"]*)"`).exec(tag)?.[1];

/** Excel's built-in date formats, and custom ones that carry a day, month or year letter outside quotes and brackets. */
const BUILTIN_DATES = new Set([14, 15, 16, 17, 22, 27, 28, 29, 30, 31, 34, 35, 36, 50, 51, 52, 53, 54, 55, 56, 57, 58]);
const looksLikeDate = (code: string) => /[dy]/i.test(code.replace(/"[^"]*"/g, "").replace(/\[[^\]]*\]/g, "").replace(/\\./g, ""));

function colIndex(ref: string): number {
  let n = 0;
  for (const ch of ref) { const c = ch.charCodeAt(0); if (c < 65 || c > 90) break; n = n * 26 + (c - 64); }
  return n - 1;
}
function isoDate(serial: number, date1904: boolean): string {
  // day 1 is 1 Jan 1900 (with Excel's phantom 29 Feb 1900), or day 0 is 1 Jan 1904
  const days = Math.floor(serial);
  const ms = date1904 ? Date.UTC(1904, 0, 1) + days * 86400000 : Date.UTC(1899, 11, 30) + (days < 60 ? days + 1 : days) * 86400000;
  return new Date(ms).toISOString().slice(0, 10);
}

/** The first sheet of a workbook as rows of text; at most `maxRows` rows are read. */
export function sheetRows(file: Buffer, maxRows = 5000): string[][] {
  const zip = unzip(file);
  const read = (name: string) => zip.get(name)?.().toString("utf8") ?? null;
  const workbook = read("xl/workbook.xml");
  if (!workbook) throw new Error("not a workbook");
  const date1904 = /<workbookPr\b[^>]*\bdate1904="(1|true)"/.test(workbook);
  // the first sheet, by the workbook's own order
  const firstRel = attr(/<sheet\b[^>]*>/.exec(workbook)?.[0] ?? "", "r:id");
  const rels = read("xl/_rels/workbook.xml.rels") ?? "";
  const target = [...rels.matchAll(/<Relationship\b[^>]*>/g)].map((m) => m[0]).find((t) => attr(t, "Id") === firstRel);
  const path = target ? attr(target, "Target")!.replace(/^\/?(xl\/)?/, "xl/") : "xl/worksheets/sheet1.xml";
  const sheet = read(path);
  if (!sheet) throw new Error("the workbook has no sheet to read");
  const shared = [...(read("xl/sharedStrings.xml") ?? "").matchAll(/<si\b[^>]*>([\s\S]*?)<\/si>/g)].map((m) => textOf(m[1]!));
  const styles = read("xl/styles.xml") ?? "";
  const custom = new Map([...styles.matchAll(/<numFmt\b[^>]*>/g)].map((m) => [Number(attr(m[0], "numFmtId")), unescape(attr(m[0], "formatCode") ?? "")] as const));
  const xfs = [...(/<cellXfs\b[\s\S]*?<\/cellXfs>/.exec(styles)?.[0] ?? "").matchAll(/<xf\b[^>]*>/g)].map((m) => {
    const id = Number(attr(m[0], "numFmtId") ?? 0);
    return BUILTIN_DATES.has(id) || (custom.has(id) && looksLikeDate(custom.get(id)!));
  });
  const out: string[][] = [];
  for (const rowM of sheet.matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>|<row\b[^>]*\/>/g)) {
    if (out.length >= maxRows) break;
    const row: string[] = [];
    for (const c of (rowM[1] ?? "").matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const tag = c[1]!, body = c[2] ?? "";
      const at = colIndex(attr(tag, "r") ?? ""), type = attr(tag, "t");
      const v = /<v\b[^>]*>([\s\S]*?)<\/v>/.exec(body)?.[1];
      let text = "";
      if (type === "s") text = shared[Number(v)] ?? "";
      else if (type === "inlineStr") text = textOf(body);
      else if (type === "str" || type === "e") text = unescape(v ?? "");
      else if (type === "b") text = v === "1" ? "TRUE" : "FALSE";
      else if (v !== undefined && v !== "") {
        const n = Number(v);
        text = Number.isFinite(n) && xfs[Number(attr(tag, "s") ?? -1)] && n >= 1 && n < 2958466 ? isoDate(n, date1904) : Number.isFinite(n) && /e/i.test(v) ? String(n) : unescape(v);
      }
      const col = at >= 0 ? at : row.length;
      while (row.length < col) row.push("");
      row[col] = text.replace(/\r\n?/g, "\n").trim();
    }
    out.push(row);
  }
  // rows at the end with nothing in them are not rows
  while (out.length && out[out.length - 1]!.every((x) => !x)) out.pop();
  return out;
}

/** The same rows as CSV text, for the importer that reads CSV. */
export function sheetCsv(file: Buffer, maxRows = 5000): string {
  const rows = sheetRows(file, maxRows);
  const width = rows.reduce((m, r) => Math.max(m, r.length), 0);
  return rows.map((r) => Array.from({ length: width }, (_, i) => { const x = r[i] ?? ""; return /[",\n]/.test(x) ? `"${x.replace(/"/g, '""')}"` : x; }).join(",")).join("\n");
}
