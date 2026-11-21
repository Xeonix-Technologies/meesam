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
   "goods": "<the goods or services as printed, shortened to 200 characters, or null>",
   "applicant_name": "<as printed, or null>",
   "applicant_country": "<two-letter country code when the entry states the country, or null>",
   "applicant_address": "<as printed, shortened, or null>",
   "agent_name": "<the agent, representative or address for service as printed, or null>",
   "confidence": <0..1, how sure you are that this entry is read correctly>
 } ],
 "notes": "<anything unusual: an entry cut off at the end of the excerpt, unreadable text, a page that is not a list of marks; or null>"}
Rules:
- One entry per mark. Pages that repeat the same application number belong to the same single entry, however many pages its goods run over; never list one mark twice.
- A table of contents or index (rows giving only a number, a class and a page reference) is not a list of entries: return no marks for such pages, set page_kind to "index" and say so in notes.
- Copy numbers and names exactly as printed. Convert dates to YYYY-MM-DD (convert Hijri dates and dd/mm/yyyy). Use null where the page does not state a value; never fill a value from another entry.
- Lower the confidence where the print is unclear or the entry is incomplete in this excerpt.`;

/** The registry's own layout notes (fetch_spec.read.notes, data), added to the request when the source carries them. */
const withNotes = (notes: string | null) => (notes ? `${PROMPT}\n\n${notes}` : PROMPT);

/**
 * The first page that lists entries, found from the file's own text with the registry's marker (fetch_spec.read.entry_marker).
 * Looks at the first pages only; returns null when the file has no text layer or nothing matches.
 */
export async function firstEntryPage(file: string, marker: string, lookAt = 80): Promise<number | null> {
  let re: RegExp;
  try { re = new RegExp(marker); } catch { return null; }
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
  const t = await run("pdftotext", ["-f", "1", "-l", String(lookAt), "-enc", "UTF-8", file, "-"], env, 10 * 60 * 1000);
  if (t.code !== 0) return null;
  const pages = t.out.split("\f");   // pdftotext ends every page with a form feed
  for (let i = 0; i < pages.length; i++) if (re.test(pages[i]!)) return i + 1;
  return null;
}

async function largestPdf(dir: string): Promise<string | null> {
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
export async function cutPages(file: string, out: string, first: number, pages: number): Promise<{ pageCount: number; from: number; to: number }> {
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
  const n = await run("qpdf", ["--show-npages", file], env, 10 * 60 * 1000);
  if (n.code === 127) throw new Error("qpdf is not installed in this service");
  const pageCount = Number(n.out.trim());
  if (!(pageCount > 0)) throw new Error(`the file's pages could not be counted: ${n.err.trim().slice(-300)}`);
  const from = Math.min(Math.max(1, first), pageCount);
  const to = Math.min(pageCount, from + pages - 1);
  // exit code 3 from qpdf means "done, with warnings" (common in registry PDFs)
  const c = await run("qpdf", [file, "--pages", ".", `${from}-${to}`, "--", out], env, 20 * 60 * 1000);
  if (c.code !== 0 && c.code !== 3) throw new Error(`the pages could not be cut out: ${c.err.trim().slice(-300)}`);
  return { pageCount, from, to };
}

export interface Reading { result: unknown; inputTokens: number; outputTokens: number }

/** Sends the excerpt to the reader and returns what it read, with the size of the request and the reply. */
export async function readExcerpt(pdf: Buffer, model: string, key: string, notes: string | null = null): Promise<Reading> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 12000, system: SYSTEM,
      messages: [{ role: "user", content: [{ type: "document", source: { type: "base64", media_type: "application/pdf", data: pdf.toString("base64") } }, { type: "text", text: withNotes(notes) }] }],
    }),
    signal: AbortSignal.timeout(10 * 60 * 1000),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    const why = res.status === 401 ? "The AI provider did not accept the key in AI_PROVIDER_KEY. "
      : res.status === 400 && /credit balance/i.test(text) ? "The AI provider account has no credit. "
      : res.status === 404 ? "The AI provider does not know this model name. "
      : res.status === 429 ? "The AI provider's rate limit was reached; try again in a minute. " : "";
    throw new Error(`${why}AI reader: ${res.status} ${text.slice(0, 300)}`);
  }
  const json = (await res.json()) as { content?: Array<{ type: string; text?: string }>; usage?: { input_tokens?: number; output_tokens?: number }; stop_reason?: string };
  const text = (json.content ?? []).filter((c) => c.type === "text").map((c) => c.text ?? "").join("\n");
  const m = text.match(/\{[\s\S]*\}/);
  let result: unknown;
  try { result = m ? JSON.parse(m[0]) : null; } catch { result = null; }
  if (!result) result = { page_kind: "other", marks: [], notes: `The reply was not readable as data${json.stop_reason === "max_tokens" ? " (it was cut off at the length limit; try fewer pages)" : ""}.`, raw: text.slice(0, 2000) };
  else if (json.stop_reason === "max_tokens") (result as { notes?: string }).notes = `${(result as { notes?: string }).notes ?? ""} The reply reached the length limit; try fewer pages.`.trim();
  return { result, inputTokens: Number(json.usage?.input_tokens ?? 0), outputTokens: Number(json.usage?.output_tokens ?? 0) };
}

export async function runReadTest(conn: Db, job: Job, log: Log): Promise<void> {
  const id = String((job.payload as { id?: string }).id ?? "");
  const asWorker = <T>(q: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(q)) as unknown as T[]);
  const row = (await asWorker<{ object_key: string; container: string | null; first_page: number; pages: number; model: string; status: string; auto_start: boolean; entry_marker: string | null; notes: string | null }>(sql`
    SELECT i.object_key, i.container, t.first_page, t.pages, t.model, t.status, t.auto_start,
           s.fetch_spec -> 'read' ->> 'entry_marker' AS entry_marker, s.fetch_spec -> 'read' ->> 'notes' AS notes
      FROM watch.read_test t JOIN watch.publication_issue i ON i.id = t.issue_id JOIN watch.publication_source s ON s.id = i.source_id
     WHERE t.id = ${id}::uuid`))[0];
  if (!row || row.status === "done") return;
  await asWorker(sql`UPDATE watch.read_test SET status = 'running', started_at = now(), updated_at = now() WHERE id = ${id}::uuid`);
  const dir = await mkdtemp(path.join(os.tmpdir(), "meesam-read-"));
  try {
    const key = process.env.AI_PROVIDER_KEY;
    if (!key) throw new Error("AI_PROVIDER_KEY is not set on the worker service");
    const container = (row.container ?? "pdf").toLowerCase();
    const file = path.join(dir, `issue.${container}`);
    await getObjectFile(vaultConfig("PUBLICATIONS"), row.object_key, file);
    let pdf = file;
    let name = path.basename(row.object_key);
    if (container !== "pdf") {
      // an archive (the UAE bulletin is a .rar): unpack it and take the largest PDF inside
      const out = path.join(dir, "unpacked");
      const u = await run("unar", ["-quiet", "-force-overwrite", "-output-directory", out, file], { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" }, 30 * 60 * 1000);
      if (u.code === 127) throw new Error("unar is not installed in this service");
      if (u.code !== 0) throw new Error(`the archive could not be opened: ${u.err.trim().slice(-300)}`);
      const inside = await largestPdf(out);
      if (!inside) throw new Error("the archive holds no PDF file");
      pdf = inside;
      name = path.basename(inside);
    }
    const part = path.join(dir, "part.pdf");
    // no first page given: start where the entries start, by the registry's own marker; page 1 when it cannot be told
    let first = row.first_page;
    if (row.auto_start && row.entry_marker) first = (await firstEntryPage(pdf, row.entry_marker)) ?? 1;
    const cut = await cutPages(pdf, part, first, row.pages);
    const bytes = (await stat(part)).size;
    if (bytes > 25 * 1024 * 1024) throw new Error(`these ${cut.to - cut.from + 1} pages are ${Math.round(bytes / 1048576)} MB, too large to send in one request; ask for fewer pages`);
    const reading = await readExcerpt(await readFile(part), row.model, key, row.notes);
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
