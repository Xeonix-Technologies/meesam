import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { withRole, type Db, type Job } from "@meesam/db";
import { askReader, bringIssue, cutPages, entryPages, plain, withNotes } from "./read.js";

/**
 * Reading a whole issue (plan item A1; migration 0067). The issue is cut into parts at the pages where entries
 * begin, each part is sent to the AI reader, and every mark read is stored among the published marks as
 * "ai_extracted": waiting for a person to verify it. Nothing reaches an account before verification.
 *
 * The work is done in slices of a few minutes: a slice reads some parts, records them, and queues the next
 * slice, so other jobs (reminders, fetches) are never kept waiting behind a whole issue, and a restart of the
 * worker loses at most the requests in hand. The run stops itself at its size ceiling (token_cap), when the
 * provider refuses the key or the account has no credit, and when the lead stops it.
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

export interface Part { kind: "index" | "entries"; from: number; to: number }

/** Pages of one request while reading entries, pages of one request while reading the index, and the longest entry sent whole. */
export const PART_PAGES = 5;
export const INDEX_PAGES = 6;
export const WHOLE_ENTRY_PAGES = 12;

/**
 * The parts of a run. Pages before the first entry are index parts (when the registry prints an index there).
 * Entries are grouped into parts of a few pages, cut only where an entry begins, so no entry is split between
 * two requests; an entry longer than a part is a part of its own.
 */
export function planParts(starts: number[], pageCount: number, indexBefore: boolean): Part[] {
  const parts: Part[] = [];
  const s = [...new Set(starts)].filter((p) => p >= 1 && p <= pageCount).sort((a, b) => a - b);
  if (s.length === 0) return parts;
  if (indexBefore) for (let p = 1; p < s[0]!; p += INDEX_PAGES) parts.push({ kind: "index", from: p, to: Math.min(s[0]! - 1, p + INDEX_PAGES - 1) });
  let from = s[0]!;
  for (let i = 0; i < s.length; i++) {
    const end = i + 1 < s.length ? s[i + 1]! - 1 : pageCount;     // last page of entry i
    const next = i + 1 < s.length ? (i + 2 < s.length ? s[i + 2]! - 1 : pageCount) : null;   // last page of the entry after it
    // close the part here when the next entry would not fit in it
    if (next === null || next - from + 1 > PART_PAGES) { parts.push({ kind: "entries", from, to: end }); from = end + 1; }
  }
  return parts;
}

/** Which pages of a part are sent: all of them, or the first and last pages of one very long entry (its goods run over the middle). */
export function pagesToSend(p: Part): { ranges: string; trimmed: boolean } {
  const n = p.to - p.from + 1;
  if (p.kind === "index" || n <= WHOLE_ENTRY_PAGES) return { ranges: `${p.from}-${p.to}`, trimmed: false };
  return { ranges: `${p.from}-${p.from + 3},${p.to - 2}-${p.to}`, trimmed: true };
}

const INDEX_PROMPT = `The attached pages come from the front of a trademark gazette, before its entries. Some are cover or introduction pages; some are index pages: tables whose rows give a mark's application number, its class and the page on which its entry is printed.
Return one JSON object:
{"rows": [ {"application_no": "<the number as printed>", "class": <the Nice class as an integer, or null>, "page": "<the page reference as printed, or null>"} ],
 "notes": "<anything unusual, or null>"}
Rules:
- List every row of every index table on these pages, in the order printed. Copy the numbers exactly, digit by digit.
- Return no rows for pages that are not index tables.`;

const TRIMMED = `\n\nThese pages are one single long entry: its first pages and its last pages. The pages in the middle, which only continue its list of goods, were left out. Return exactly one mark.`;

interface RunRow {
  id: string; status: string; model: string; token_cap: string; input_tokens: string; output_tokens: string; parts_total: number; issue_id: string;
  object_key: string; container: string | null; entry_start: string | null; notes: string | null; index_before: boolean;
}

export async function runReadRun(conn: Db, job: Job, log: Log): Promise<void> {
  const payload = job.payload as { id?: string; step?: number };
  const id = String(payload.id ?? "");
  const step = Number(payload.step ?? 0);
  const q = <T>(query: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(query)) as unknown as T[]);
  const load = async () => (await q<RunRow>(sql`
    SELECT u.id, u.status, u.model, u.token_cap::text, u.input_tokens::text, u.output_tokens::text, u.parts_total, u.issue_id,
           i.object_key, i.container, COALESCE(s.fetch_spec -> 'read' ->> 'entry_start', s.fetch_spec -> 'read' ->> 'entry_marker') AS entry_start,
           s.fetch_spec -> 'read' ->> 'notes' AS notes, COALESCE(s.fetch_spec -> 'read' ->> 'index', '') = 'before_entries' AS index_before
      FROM watch.read_run u JOIN watch.publication_issue i ON i.id = u.issue_id JOIN watch.publication_source s ON s.id = i.source_id
     WHERE u.id = ${id}::uuid`))[0];
  let run = await load();
  if (!run || !["queued", "reading"].includes(run.status)) return;
  const dir = path.join(os.tmpdir(), `meesam-run-${id}`);
  const end = async (status: "done" | "failed" | "stopped", error: string | null) => {
    // a run the lead stopped keeps its own wording; what was read is compared with the index either way
    await q(sql`UPDATE watch.read_run SET status = CASE WHEN status = 'stopped' THEN status ELSE ${status} END, error = COALESCE(error, ${error}),
      outcome = watch.fn_read_run_outcome(id), finished_at = COALESCE(finished_at, now()), updated_at = now() WHERE id = ${id}::uuid`);
    await rm(dir, { recursive: true, force: true });
    log(status === "done" ? "info" : "error", `read_run.${status}`, { id, error });
  };
  const next = async (delaySeconds: number) => {
    await q(sql`SELECT platform.enqueue_job('watch.read_run', ${JSON.stringify({ id, step: step + 1 })}::jsonb, now() + make_interval(secs => ${delaySeconds}::int), ${`watch.read_run:${id}:${step + 1}`})`);
  };
  try {
    const key = process.env.AI_PROVIDER_KEY;
    if (!key) throw new Error("AI_PROVIDER_KEY is not set on the worker service");
    if (!run.entry_start) throw new Error("This registry's layout is not entered yet, so the issue cannot be cut into its entries.");

    // the issue file is kept in scratch space between slices; after a restart it is brought again
    await mkdir(dir, { recursive: true });
    const noteFile = path.join(dir, "pdf.json");
    let pdf: string; let name: string;
    try { ({ pdf, name } = JSON.parse(await readFile(noteFile, "utf8")) as { pdf: string; name: string }); await stat(pdf); }
    catch { ({ pdf, name } = await bringIssue(dir, run.object_key, run.container)); await writeFile(noteFile, JSON.stringify({ pdf, name })); }

    if (run.status === "queued") {
      const found = await entryPages(pdf, plain(run.entry_start));
      if (found.pages.length === 0) return await end("failed", `The pages where entries begin could not be found: ${found.why}.`);
      const cut = await cutPages(pdf, path.join(dir, "probe.pdf"), 1, 1);
      const parts = planParts(found.pages, cut.pageCount, run.index_before);
      await withRole(conn, "meesam_worker", async (tx) => {
        await tx.execute(sql`DELETE FROM watch.read_part WHERE run_id = ${id}::uuid`);
        await tx.execute(sql`INSERT INTO watch.read_part (run_id, seq, kind, from_page, to_page)
          SELECT ${id}::uuid, (x ->> 'seq')::int, x ->> 'kind', (x ->> 'from')::int, (x ->> 'to')::int FROM jsonb_array_elements(${JSON.stringify(parts.map((p, i) => ({ ...p, seq: i + 1 })))}::jsonb) x`);
        await tx.execute(sql`UPDATE watch.read_run SET status = 'reading', started_at = now(), file_name = ${name.slice(0, 200)}, page_count = ${cut.pageCount}::int,
          first_page = ${found.pages[0]!}::int, entries_found = ${found.pages.length}::int, parts_total = ${parts.length}::int, updated_at = now() WHERE id = ${id}::uuid AND status = 'queued'`);
      });
      log("info", "read_run.planned", { id, pages: cut.pageCount, entries: found.pages.length, parts: parts.length });
    }

    // one slice: parts are read two at a time for about two and a half minutes
    const started = Date.now();
    // wait: seconds before the next slice (the provider asked us to slow down); fatal: nothing more can be read
    const state: { wait: number; fatal: string | null } = { wait: 0, fatal: null };
    const one = async (p: { seq: number; kind: "index" | "entries"; from_page: number; to_page: number; attempts: number }) => {
      const part: Part = { kind: p.kind, from: p.from_page, to: p.to_page };
      const send = pagesToSend(part);
      const file = path.join(dir, `part-${p.seq}.pdf`);
      try {
        await cutPages(pdf, file, p.from_page, p.to_page - p.from_page + 1, send.ranges);
        const bytes = (await stat(file)).size;
        if (bytes > 25 * 1024 * 1024) throw new Error(`pages ${p.from_page}–${p.to_page} are ${Math.round(bytes / 1048576)} MB, too large to send in one request`);
        const question = p.kind === "index" ? INDEX_PROMPT : `${withNotes(run!.notes, null)}${send.trimmed ? TRIMMED : ""}`;
        const reading = await askReader(await readFile(file), run!.model, key, question);
        const result = (reading.result ?? {}) as { marks?: Array<Record<string, unknown>>; rows?: unknown[] };
        const marks = p.kind === "entries" && Array.isArray(result.marks) ? result.marks : [];
        await withRole(conn, "meesam_worker", async (tx) => {
          for (const m of marks) {
            // the page in the whole file: a part of one entry begins on its first page; otherwise count from the part's first page
            const inPart = typeof m.page === "number" && m.page >= 1 ? m.page : 1;
            const page = send.trimmed ? p.from_page : Math.min(p.to_page, p.from_page + inPart - 1);
            await tx.execute(sql`SELECT watch.fn_read_mark_store(${id}::uuid, ${JSON.stringify({ ...m, page })}::jsonb)`);
          }
          await tx.execute(sql`UPDATE watch.read_part SET status = 'done', attempts = attempts + 1, input_tokens = ${reading.inputTokens}::int, output_tokens = ${reading.outputTokens}::int,
            result = ${JSON.stringify(result)}::jsonb, error = NULL, updated_at = now() WHERE run_id = ${id}::uuid AND seq = ${p.seq}::int`);
          await tx.execute(sql`UPDATE watch.read_run SET input_tokens = input_tokens + ${reading.inputTokens}::int, output_tokens = output_tokens + ${reading.outputTokens}::int, updated_at = now() WHERE id = ${id}::uuid`);
        });
      } catch (e) {
        const err = e as Error & { status?: number; credit?: boolean; cause?: { message?: string } };
        const message = (err.cause?.message && !err.status ? `${err.message}: ${err.cause.message}` : err.message).slice(0, 600);
        if (err.status === 429 || err.status === 529) { state.wait = 60; return; }                  // busy: the part stays waiting, the run slows down
        if (err.status === 401 || err.status === 403 || err.status === 404 || err.credit) { state.fatal = message; return; }   // nothing more can be read
        await q(sql`UPDATE watch.read_part SET attempts = attempts + 1, status = CASE WHEN attempts + 1 >= 3 THEN 'failed' ELSE 'waiting' END, error = ${message}, updated_at = now()
          WHERE run_id = ${id}::uuid AND seq = ${p.seq}::int`);
        log("error", "read_run.part", { id, seq: p.seq, message });
      } finally {
        await rm(file, { force: true });
      }
    };
    while (Date.now() - started < 150_000 && !state.wait && !state.fatal) {
      run = await load();
      if (!run || run.status !== "reading") return await end("stopped", null);     // stopped by the lead: what was read is still compared
      const used = Number(run.input_tokens) + Number(run.output_tokens);
      if (used >= Number(run.token_cap)) return await end("stopped", `The size ceiling of this reading was reached (${used.toLocaleString("en")} tokens). The marks read so far are kept.`);
      const waiting = await q<{ seq: number; kind: "index" | "entries"; from_page: number; to_page: number; attempts: number }>(sql`
        SELECT seq, kind, from_page, to_page, attempts FROM watch.read_part WHERE run_id = ${id}::uuid AND status = 'waiting' ORDER BY attempts, seq LIMIT 2`);
      if (waiting.length === 0) {
        const read = (await q<{ n: number }>(sql`SELECT count(*)::int AS n FROM watch.read_part WHERE run_id = ${id}::uuid AND kind = 'entries' AND status = 'done'`))[0]?.n ?? 0;
        return await end(read > 0 ? "done" : "failed", read > 0 ? null : "No part of the issue could be read.");
      }
      await Promise.all(waiting.map(one));
    }
    if (state.fatal) return await end("failed", state.fatal);
    await next(state.wait);
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    await end("failed", (err.cause?.message ? `${err.message}: ${err.cause.message}` : err.message).slice(0, 900));
  }
}
