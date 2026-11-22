import { spawn } from "node:child_process";
import { mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { withRole, type Db } from "@meesam/db";
import { bringIssue, cutPages } from "./read.js";
import { CodesReader, headOf, linesOf, pagesFromBbox, printedPage, rangesToRead, sectionsFromContents, type CodesMark, type CodesSpec } from "./codes.js";

/**
 * Reading an issue by its printed codes (migration 0081; Founder ruling 22 Nov 2026). No AI reader is asked and
 * nothing is paid: the entries are taken from the file's own text with the source's settings (fetch_spec.read).
 *
 * A whole issue: the contents page gives the sections; those whose title matches the source's pattern are read,
 * each from its first page to the page before the next section. The office's own list of numbers at the head of
 * each section is kept as the run's index, so what was read is compared with it like any other reading.
 * Some pages only: the entries that begin on those pages are read, each to its end.
 *
 * Every mark is stored as "waiting for a person", exactly as a mark read by the AI reader is (rule 7).
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

/** pages given to pdftotext at a time, and how far past the last asked page an entry is followed to its end */
const CHUNK = 100;
const FOLLOW = 40;

export interface CodesRun { id: string; issue_id: string; object_key: string; container: string | null; from_page: number | null; to_page: number | null; spec: CodesSpec }

const ENV = () => ({ PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" });

/**
 * A command's whole output. (The worker's general helper keeps only the first 4 MB of an output, which is right for
 * logs; the words of a hundred pages with their places are larger, and a cut output would lose pages silently.)
 */
function capture(cmd: string, args: string[], timeoutMs: number): Promise<{ code: number; out: string; err: string }> {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { env: ENV(), stdio: ["ignore", "pipe", "pipe"] });
    const chunks: Buffer[] = []; let size = 0; let err = ""; let over = false;
    p.stdout.on("data", (d: Buffer) => { size += d.length; if (size > 400 * 1024 * 1024) { over = true; p.kill("SIGKILL"); } else chunks.push(d); });
    p.stderr.on("data", (d: Buffer) => { if (err.length < 20_000) err += d.toString(); });
    const timer = setTimeout(() => { err += `\n${cmd} stopped after ${Math.round(timeoutMs / 60000)} minutes`; p.kill("SIGKILL"); }, timeoutMs);
    p.on("error", (e) => { clearTimeout(timer); resolve({ code: 127, out: "", err: `${cmd}: ${e.message}` }); });
    p.on("close", (code) => { clearTimeout(timer); resolve({ code: over ? 1 : code ?? 1, out: over ? "" : Buffer.concat(chunks).toString("utf8"), err: over ? `${cmd} gave more output than can be held` : err }); });
  });
}

async function words(pdf: string, from: number, to: number) {
  const t = await capture("pdftotext", ["-bbox", "-f", String(from), "-l", String(to), "-enc", "UTF-8", pdf, "-"], 20 * 60 * 1000);
  if (t.code === 127) throw new Error("pdftotext is not installed in this service");
  if (t.code !== 0) throw new Error(`pages ${from} to ${to} could not be read as text (pdftotext ended with code ${t.code}${t.err.trim() ? `: ${t.err.trim().slice(-160)}` : ""})`);
  const pages = pagesFromBbox(t.out);
  // every page asked for must come back, or entries would be lost without a word
  if (pages.length !== to - from + 1) throw new Error(`pages ${from} to ${to}: ${pages.length} of ${to - from + 1} pages came back from the file's text`);
  return pages;
}

export async function runCodesRun(conn: Db, r: CodesRun, log: Log): Promise<void> {
  const id = r.id; const spec = r.spec;
  const q = <T>(query: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(query)) as unknown as T[]);
  const dir = path.join(os.tmpdir(), `meesam-run-${id}`);
  const columns = spec.columns ?? 2; const head = spec.head_height ?? 32;
  let marks = 0;
  const end = async (status: "done" | "failed" | "stopped", error: string | null) => {
    await q(sql`UPDATE watch.read_run SET status = CASE WHEN status = 'stopped' THEN status ELSE ${status} END, error = COALESCE(error, ${error}),
      outcome = watch.fn_read_run_outcome(id), finished_at = COALESCE(finished_at, now()), updated_at = now() WHERE id = ${id}::uuid`);
    await rm(dir, { recursive: true, force: true });
    // a short reading has its pages cut out for the reviewer at once; for a whole issue they are cut when a reviewer opens a mark
    if (marks > 0 && marks <= 300) await q(sql`SELECT platform.enqueue_job('watch.mark_pages', jsonb_build_object('issue_id', ${r.issue_id}::uuid), now(), ${`watch.mark_pages:${r.issue_id}`})`);
    log(status === "done" ? "info" : "error", `read_run.${status}`, { id, by: "codes", marks, error });
  };
  const store = async (seq: number, got: CodesMark[]) => {
    await withRole(conn, "meesam_worker", async (tx) => {
      for (const m of got) await tx.execute(sql`SELECT watch.fn_read_mark_store(${id}::uuid, ${JSON.stringify(m)}::jsonb)`);
      await tx.execute(sql`UPDATE watch.read_part SET status = 'done', attempts = attempts + 1, input_tokens = 0, output_tokens = 0, result = ${JSON.stringify({ marks: got.length, by: "codes" })}::jsonb, error = NULL, updated_at = now()
        WHERE run_id = ${id}::uuid AND seq = ${seq}::int`);
    });
    marks += got.length;
  };
  try {
    if (!spec?.codes?.number || !spec.codes.applicant || !spec.codes.mark || !spec.codes.classes || !spec.codes.goods) throw new Error("This source's settings for reading by codes are incomplete.");
    await mkdir(dir, { recursive: true });
    const { pdf, name } = await bringIssue(dir, r.object_key, r.container);
    const pageCount = (await cutPages(pdf, path.join(dir, "probe.pdf"), 1, 1)).pageCount;
    const ranged = r.from_page !== null && r.to_page !== null;

    // what to read
    let ranges: Array<{ title: string; from: number; to: number }>;
    if (ranged) ranges = [{ title: "", from: Math.min(r.from_page!, pageCount), to: Math.min(r.to_page!, pageCount) }];
    else {
      if (!spec.toc_heading || !spec.sections) throw new Error("This source's settings do not say where the contents page is or which sections publish applications.");
      const front = await capture("pdftotext", ["-f", "1", "-l", "12", "-enc", "UTF-8", pdf, "-"], 10 * 60 * 1000);
      const contents = front.out.split("\f").find((p) => p.includes(spec.toc_heading!));
      if (!contents) return await end("failed", `The contents page ("${spec.toc_heading}") was not found in the first 12 pages. To read a part of a file, give the first and last page.`);
      ranges = rangesToRead(sectionsFromContents(contents), spec.sections, pageCount);
      if (ranges.length === 0) return await end("failed", "The contents page lists no section that publishes applications.");
    }

    // the parts: per section, one for the office's list of numbers and one for every hundred pages
    const parts: Array<{ kind: "index" | "entries"; from: number; to: number; range: number }> = [];
    ranges.forEach((g, i) => {
      if (!ranged) parts.push({ kind: "index", from: g.from, to: g.from, range: i });
      for (let a = g.from; a <= g.to; a += CHUNK) parts.push({ kind: "entries", from: a, to: Math.min(g.to, a + CHUNK - 1), range: i });
    });
    await withRole(conn, "meesam_worker", async (tx) => {
      await tx.execute(sql`DELETE FROM watch.read_part WHERE run_id = ${id}::uuid`);
      await tx.execute(sql`INSERT INTO watch.read_part (run_id, seq, kind, from_page, to_page)
        SELECT ${id}::uuid, (x ->> 'seq')::int, x ->> 'kind', (x ->> 'from')::int, (x ->> 'to')::int FROM jsonb_array_elements(${JSON.stringify(parts.map((p, i) => ({ ...p, seq: i + 1 })))}::jsonb) x`);
      await tx.execute(sql`UPDATE watch.read_run SET status = 'reading', started_at = now(), file_name = ${name.slice(0, 200)}, page_count = ${pageCount}::int,
        first_page = ${ranges[0]!.from}::int, parts_total = ${parts.length}::int, updated_at = now() WHERE id = ${id}::uuid AND status = 'queued'`);
    });
    log("info", "read_run.planned", { id, by: "codes", pages: pageCount, sections: ranges.length, parts: parts.length });

    let entries = 0;
    for (let g = 0; g < ranges.length; g++) {
      const reader = new CodesReader(spec);
      const mine = parts.map((p, i) => ({ ...p, seq: i + 1 })).filter((p) => p.range === g);
      for (const p of mine.filter((x) => x.kind === "entries")) {
        const state = (await q<{ status: string }>(sql`SELECT status FROM watch.read_run WHERE id = ${id}::uuid`))[0]?.status;
        if (state !== "reading") return await end("stopped", null);
        const got: CodesMark[] = [];
        (await words(pdf, p.from, p.to)).forEach((pg, i) => got.push(...reader.feed(linesOf(pg, p.from + i, columns, head), printedPage(headOf(pg, head)))));
        const last = p.to === ranges[g]!.to;
        if (last && !ranged) got.push(...reader.end());
        if (last && ranged) {
          // the entry still open at the last asked page is followed to its end, and nothing after it is taken
          let closed = false;
          for (let a = p.to + 1; a <= Math.min(pageCount, p.to + FOLLOW) && !closed; a++) {
            const pg = (await words(pdf, a, a))[0];
            if (!pg) break;
            const more = reader.feed(linesOf(pg, a, columns, head), printedPage(headOf(pg, head)));
            if (more.length) { got.push(more[0]!); closed = true; }
          }
          if (!closed) got.push(...reader.end().map((m) => ({ ...m, confidence: Math.min(m.confidence, 0.5), notes: [m.notes, "the entry may run beyond the pages that were read"].filter(Boolean).join("; ") })));
        }
        await store(p.seq, got);
        entries += got.length;
      }
      // the office's own list of the numbers published in this section, for the comparison
      const idx = mine.find((x) => x.kind === "index");
      if (idx) {
        await q(sql`UPDATE watch.read_part SET status = 'done', attempts = 1, input_tokens = 0, output_tokens = 0, updated_at = now(),
          result = ${JSON.stringify({ rows: [...new Set(reader.index)].map((n) => ({ application_no: n })), section: ranges[g]!.title })}::jsonb WHERE run_id = ${id}::uuid AND seq = ${idx.seq}::int`);
      }
    }
    await q(sql`UPDATE watch.read_run SET entries_found = ${entries}::int, updated_at = now() WHERE id = ${id}::uuid`);
    return await end(entries > 0 ? "done" : "failed", entries > 0 ? null : "No entry was found on these pages.");
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    await end("failed", (err.cause?.message ? `${err.message}: ${err.cause.message}` : err.message).slice(0, 900));
  }
}
