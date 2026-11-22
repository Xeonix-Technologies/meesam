import { readdir, readFile, mkdtemp, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { getObjectFile, vaultConfig, withRole, type Db, type Job } from "@meesam/db";
import { run } from "../backup.js";

/**
 * Reading test (plan item A1, first step; migration 0064): a few pages of a stored issue are sent to the AI reader
 * and what it read is kept beside the test, for the watch operations lead to look at. Nothing is loaded among the
 * published marks and nothing reaches an account.
 *
 * The issue file is brought from the publications bucket to scratch space, unpacked where it is an archive (the
 * UAE bulletin arrives as .rar), the asked pages are cut out with qpdf, and only those pages are sent.
 * Provider: Anthropic Messages API, key in AI_PROVIDER_KEY (configuration, never code).
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const SYSTEM = `You read pages of official trademark gazettes and bulletins published by national trademark offices (for example the UAE Ministry of Economy and Tourism, Qatar, Türkiye, the USPTO, the UK IPO), in Arabic, English, Turkish or other languages. You extract exactly what is printed. You never guess, complete or translate a value that is not on the page. Return only JSON, with no text before or after it.`;

const PROMPT = `The attached PDF is an excerpt of a trademark gazette. List every trademark entry printed on these pages.
Return one JSON object:
{"page_kind": "<applications|registrations|renewals|changes|index|cover|other>",
 "language": "<main language of the pages>",
 "marks": [ {
   "page": <page inside this excerpt where the entry begins, starting at 1>,
   "printed_page": "<the page number printed on that page, as printed, or null>",
   "pages": <how many pages of this excerpt the entry covers>,
   "continues": <true when the entry began before this excerpt or runs beyond its last page>,
   "application_no": "<application or filing number as printed, or null>",
   "registration_no": "<registration number as printed, or null>",
   "filing_date": "<YYYY-MM-DD or null>",
   "mark_text_ar": "<the mark's wording in Arabic script as printed, or null>",
   "mark_text_en": "<the mark's wording in Latin script as printed, or null>",
   "mark_type": "<word|device|combined>",
   "has_image": <true when a picture or logo of the mark is printed>,
   "image_description": "<one short neutral sentence describing the picture, or null>",
   "classes": [<every Nice class the entry states, as integers>],
   "goods": "<the goods or services exactly as printed, in full; if the list is longer than 3000 characters, its first 3000 followed by ' …'; or null>",
   "applicant_name": "<as printed, or null>",
   "applicant_country": "<two-letter country code when the entry states the country, or null>",
   "applicant_address": "<as printed, shortened, or null>",
   "agent_name": "<the agent, representative or address for service as printed, without the city, or null>",
   "agent_city": "<the city printed with the agent, or null>",
   "confidence": <0..1, how sure you are that this entry is read correctly>
 } ],
 "notes": "<anything unusual: an entry cut off at the end of the excerpt, unreadable text, a page that is not a list of marks; or null>"}
Rules:
- Where Latin letters and digits stand inside Arabic text (a shop, plot or unit code, a postal code, a company number), copy them exactly as they are printed on the page, reading the code left to right. The file's hidden text layer can hold such codes in another order: go by the page as printed.
- One entry per mark. Pages that repeat the same application number belong to the same single entry, however many pages its goods run over; never list one mark twice.
- A table of contents or index (rows giving only a number, a class and a page reference) is not a list of entries: return no marks for such pages, set page_kind to "index" and say so in notes.
- Copy numbers and names exactly as printed. Convert dates to YYYY-MM-DD (convert Hijri dates and dd/mm/yyyy). Use null where the page does not state a value; never fill a value from another entry.
- Lower the confidence where the print is unclear or the entry is incomplete in this excerpt.`;

/** The registry's own layout notes (fetch_spec.read.notes, data), added to the request when the source carries them. */
/** The request for a translation beside what is printed, in the language named (a two-letter code); what is printed is never replaced. */
const translation = (lang: string | null): string => {
  if (!lang) return "";
  let name = lang;
  try { name = new Intl.DisplayNames(["en"], { type: "language" }).of(lang) ?? lang; } catch { /* keep the code */ }
  return `\n\nTranslation. Beside the fields above, add these to every entry, in ${name}:
"applicant_name_t": the applicant's name written in ${name} (write a name in that language's script as it sounds, or use the company's own name in that script when you can see it in the entry; translate words for the legal form such as company or limited),
"agent_name_t": the agent's name, the same way,
"goods_t": the goods or services translated into ${name}, shortened to 200 characters,
"mark_meaning_t": what the mark's wording means in ${name} when it is a word with a meaning in another language, otherwise null.
Never change the original fields: they stay exactly as printed. Do not translate the mark's wording itself into the original fields.`;
};
export const withNotes = (notes: string | null, lang: string | null) => `${PROMPT}${notes ? `\n\n${notes}` : ""}${translation(lang)}`;

/**
 * Text as a person would type it: Arabic presentation forms folded to plain letters, and the elongation mark,
 * vowel marks and direction marks removed. PDFs often store Arabic in these other forms, or in visual (reversed) order.
 */
export const plain = (t: string) => t.normalize("NFKC").replace(/[\u0640\u064B-\u065F\u0670\u200B-\u200F\u202A-\u202E\u2066-\u2069]/g, "");

export interface StartFound { page: number | null; scanned: number; why: string }

/**
 * The first page that lists entries, found from the file's own text with the registry's marker (fetch_spec.read.entry_marker).
 * Looks at the first pages only. Says what happened when it cannot tell, so a wrong start is never silent.
 */
export async function firstEntryPage(file: string, marker: string, lookAt = 80): Promise<StartFound> {
  let re: RegExp;
  try { re = new RegExp(marker); } catch { return { page: null, scanned: 0, why: "the registry's marker is not a valid pattern" }; }
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
  const t = await run("pdftotext", ["-f", "1", "-l", String(lookAt), "-enc", "UTF-8", file, "-"], env, 10 * 60 * 1000);
  if (t.code === 127) return { page: null, scanned: 0, why: "pdftotext is not installed in this service" };
  if (!t.out.trim()) return { page: null, scanned: 0, why: `the file gave no text (pdftotext ended with code ${t.code}${t.err.trim() ? `: ${t.err.trim().slice(-160)}` : ""})` };
  const pages = t.out.split("\f");   // pdftotext ends every page with a form feed
  for (let i = 0; i < pages.length; i++) {
    const text = plain(pages[i]!);
    // also line by line in reverse, for files that store Arabic in the order it is drawn
    if (re.test(text) || re.test(text.split("\n").map((l) => [...l].reverse().join("")).join("\n"))) return { page: i + 1, scanned: pages.length, why: "found" };
  }
  return { page: null, scanned: pages.length, why: `the registry's marker was not found in the first ${pages.length} pages of the file's text` };
}

/**
 * Every page on which an entry begins, found from the file's own text with the registry's marker
 * (fetch_spec.read.entry_start). The whole file is looked at. An empty list comes with the reason.
 */
export async function entryPages(file: string, marker: string): Promise<{ pages: number[]; scanned: number; why: string }> {
  let re: RegExp;
  try { re = new RegExp(marker); } catch { return { pages: [], scanned: 0, why: "the registry's marker is not a valid pattern" }; }
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
  const t = await run("pdftotext", ["-enc", "UTF-8", file, "-"], env, 20 * 60 * 1000);
  if (t.code === 127) return { pages: [], scanned: 0, why: "pdftotext is not installed in this service" };
  if (!t.out.trim()) return { pages: [], scanned: 0, why: `the file gave no text (pdftotext ended with code ${t.code}${t.err.trim() ? `: ${t.err.trim().slice(-160)}` : ""})` };
  const all = t.out.split("\f");
  const pages: number[] = [];
  all.forEach((raw, i) => {
    const text = plain(raw);
    if (re.test(text) || re.test(text.split("\n").map((l) => [...l].reverse().join("")).join("\n"))) pages.push(i + 1);
  });
  return { pages, scanned: all.length, why: pages.length ? "found" : `the registry's marker was not found in the ${all.length} pages of the file's text` };
}

/** The issue file brought from the publications bucket into a folder, unpacked where it is an archive. Returns the PDF to read and its name. */
export async function bringIssue(dir: string, objectKey: string, containerOf: string | null): Promise<{ pdf: string; name: string }> {
  const container = (containerOf ?? "pdf").toLowerCase();
  const file = path.join(dir, `issue.${container}`);
  await getObjectFile(vaultConfig("PUBLICATIONS"), objectKey, file);
  if (container === "pdf") return { pdf: file, name: path.basename(objectKey) };
  // an archive (the UAE bulletin is a .rar): unpack it and take the largest PDF inside
  const out = path.join(dir, "unpacked");
  const u = await run("unar", ["-quiet", "-force-overwrite", "-output-directory", out, file], { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" }, 30 * 60 * 1000);
  if (u.code === 127) throw new Error("unar is not installed in this service");
  if (u.code !== 0) throw new Error(`the archive could not be opened: ${u.err.trim().slice(-300)}`);
  const inside = await largestPdf(out);
  if (!inside) throw new Error("the archive holds no PDF file");
  return { pdf: inside, name: path.basename(inside) };
}

export async function largestPdf(dir: string): Promise<string | null> {
  let best: { file: string; size: number } | null = null;
  const walk = async (d: string): Promise<void> => {
    for (const e of await readdir(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) await walk(p);
      else if (/\.pdf$/i.test(e.name)) { const s = (await stat(p)).size; if (!best || s > best.size) best = { file: p, size: s }; }
    }
  };
  await walk(dir);
  return best ? (best as { file: string }).file : null;
}

/** The pages asked for, as their own small PDF. Returns the number of pages in the whole file and the range taken. */
export async function cutPages(file: string, out: string, first: number, pages: number, ranges?: string): Promise<{ pageCount: number; from: number; to: number }> {
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
  const n = await run("qpdf", ["--show-npages", file], env, 10 * 60 * 1000);
  if (n.code === 127) throw new Error("qpdf is not installed in this service");
  const pageCount = Number(n.out.trim());
  if (!(pageCount > 0)) throw new Error(`the file's pages could not be counted: ${n.err.trim().slice(-300)}`);
  const from = Math.min(Math.max(1, first), pageCount);
  const to = Math.min(pageCount, from + pages - 1);
  // exit code 3 from qpdf means "done, with warnings" (common in registry PDFs)
  const c = await run("qpdf", [file, "--pages", ".", ranges ?? `${from}-${to}`, "--", out], env, 20 * 60 * 1000);
  if (c.code !== 0 && c.code !== 3) throw new Error(`the pages could not be cut out: ${c.err.trim().slice(-300)}`);
  return { pageCount, from, to };
}

/** `cut`: the reply reached the length limit, so it may be incomplete. */
export interface Reading { result: unknown; inputTokens: number; outputTokens: number; cut: boolean }

/** Sends the excerpt to the reader and returns what it read, with the size of the request and the reply. */
export const readExcerpt = (pdf: Buffer, model: string, key: string, notes: string | null = null, lang: string | null = null): Promise<Reading> =>
  askReader(pdf, model, key, withNotes(notes, lang));

/** One request to the reader: the pages and the question. A refusal by the provider is thrown with its HTTP status. */
export async function askReader(pdf: Buffer, model: string, key: string, question: string, maxTokens = 12000): Promise<Reading> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: maxTokens, system: SYSTEM,
      messages: [{ role: "user", content: [{ type: "document", source: { type: "base64", media_type: "application/pdf", data: pdf.toString("base64") } }, { type: "text", text: question }] }],
    }),
    signal: AbortSignal.timeout(10 * 60 * 1000),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    const why = res.status === 401 ? "The AI provider did not accept the key in AI_PROVIDER_KEY. "
      : res.status === 400 && /credit balance/i.test(text) ? "The AI provider account has no credit. "
      : res.status === 404 ? "The AI provider does not know this model name. "
      : res.status === 429 ? "The AI provider's rate limit was reached; try again in a minute. " : "";
    throw Object.assign(new Error(`${why}AI reader: ${res.status} ${text.slice(0, 300)}`), { status: res.status, credit: res.status === 400 && /credit balance/i.test(text) });
  }
  const json = (await res.json()) as { content?: Array<{ type: string; text?: string }>; usage?: { input_tokens?: number; output_tokens?: number }; stop_reason?: string };
  const text = (json.content ?? []).filter((c) => c.type === "text").map((c) => c.text ?? "").join("\n");
  const m = text.match(/\{[\s\S]*\}/);
  let result: unknown;
  try { result = m ? JSON.parse(m[0]) : null; } catch { result = null; }
  if (!result) result = { page_kind: "other", marks: [], notes: `The reply was not readable as data${json.stop_reason === "max_tokens" ? " (it was cut off at the length limit; try fewer pages)" : ""}.`, raw: text.slice(0, 2000) };
  else if (json.stop_reason === "max_tokens") (result as { notes?: string }).notes = `${(result as { notes?: string }).notes ?? ""} The reply reached the length limit; try fewer pages.`.trim();
  return { result, inputTokens: Number(json.usage?.input_tokens ?? 0), outputTokens: Number(json.usage?.output_tokens ?? 0), cut: json.stop_reason === "max_tokens" };
}

export async function runReadTest(conn: Db, job: Job, log: Log): Promise<void> {
  const id = String((job.payload as { id?: string }).id ?? "");
  const asWorker = <T>(q: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(q)) as unknown as T[]);
  const row = (await asWorker<{ object_key: string; container: string | null; first_page: number; pages: number; model: string; status: string; auto_start: boolean; translate_to: string | null; entry_marker: string | null; notes: string | null }>(sql`
    SELECT i.object_key, i.container, t.first_page, t.pages, t.model, t.status, t.auto_start, t.translate_to,
           s.fetch_spec -> 'read' ->> 'entry_marker' AS entry_marker, s.fetch_spec -> 'read' ->> 'notes' AS notes
      FROM watch.read_test t JOIN watch.publication_issue i ON i.id = t.issue_id JOIN watch.publication_source s ON s.id = i.source_id
     WHERE t.id = ${id}::uuid`))[0];
  if (!row || row.status === "done") return;
  await asWorker(sql`UPDATE watch.read_test SET status = 'running', started_at = now(), updated_at = now() WHERE id = ${id}::uuid`);
  const dir = await mkdtemp(path.join(os.tmpdir(), "meesam-read-"));
  try {
    const key = process.env.AI_PROVIDER_KEY;
    if (!key) throw new Error("AI_PROVIDER_KEY is not set on the worker service");
    const { pdf, name } = await bringIssue(dir, row.object_key, row.container);
    const part = path.join(dir, "part.pdf");
    // no first page given: start where the entries start, by the registry's own marker; page 1 when it cannot be told
    let first = row.first_page;
    let startNote: string | null = null;
    if (row.auto_start) {
      if (!row.entry_marker) throw new Error("This registry's layout is not entered yet, so the first page of entries cannot be found: give a first page.");
      const found = await firstEntryPage(pdf, plain(row.entry_marker));
      // a start that cannot be found is said, not replaced by page 1 (staging, 21 Nov 2026: a silent page 1 read the cover)
      if (!found.page) throw new Error(`The first page of entries could not be found: ${found.why}. Give a first page instead.`);
      first = found.page;
      startNote = `Entries start on PDF page ${found.page}.`;
    }
    const cut = await cutPages(pdf, part, first, row.pages);
    const bytes = (await stat(part)).size;
    if (bytes > 25 * 1024 * 1024) throw new Error(`these ${cut.to - cut.from + 1} pages are ${Math.round(bytes / 1048576)} MB, too large to send in one request; ask for fewer pages`);
    const reading = await readExcerpt(await readFile(part), row.model, key, row.notes, row.translate_to);
    if (startNote && reading.result && typeof reading.result === "object") (reading.result as { start?: string }).start = startNote;
    await asWorker(sql`UPDATE watch.read_test SET status = 'done', finished_at = now(), file_name = ${name.slice(0, 200)}, page_count = ${cut.pageCount}::int,
      first_page = ${cut.from}::int, pages = ${cut.to - cut.from + 1}::int, input_tokens = ${reading.inputTokens}::int, output_tokens = ${reading.outputTokens}::int,
      result = ${JSON.stringify(reading.result)}::jsonb, updated_at = now() WHERE id = ${id}::uuid`);
    log("info", "read_test.done", { id, model: row.model, pages: cut.to - cut.from + 1, input: reading.inputTokens, output: reading.outputTokens });
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    const message = (err.cause?.message && !/^AI reader|^The AI/.test(err.message) ? `${err.message}: ${err.cause.message}` : err.message).slice(0, 900);
    await asWorker(sql`UPDATE watch.read_test SET status = 'failed', finished_at = now(), error = ${message}, updated_at = now() WHERE id = ${id}::uuid`);
    log("error", "read_test.failed", { id, message });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
