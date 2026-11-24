import { mkdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { withRole, type Db } from "@meesam/db";
import { bringIssue, bringIssueAll, cutPages } from "./read.js";
import { capture } from "./read-codes.js";
import { arabicOrderInPlace } from "./arabic-order.js";
import { FormReader, TableReader, formOf, formsOf, markOf, noticeOf, pagesOf, type Entry, type FormSpec, type LabelsMark, type LabelsNotice, type LabelsSpec, type LPage } from "./labels.js";

/**
 * Reading an issue by its printed labels (migration 0087; Founder rulings 22 and 24 Nov 2026). No AI reader is asked
 * and nothing is paid: the notices are taken from the file's own text with the source's settings (fetch_spec.read).
 *
 * A whole issue: every PDF of the issue (one file, or the parts inside its archive) is looked at; the title on its
 * first page tells which form it holds, and it is read on that form. A part that publishes applications gives
 * marks, stored as "waiting for a person" like any other reading; where the source's settings say so, the complete
 * ones are accepted without a person when the reading ends. Any other part (changes, transfers, registrations,
 * renewals) is stored with its source among the published notices and shown nowhere yet (Founder, 24 Nov 2026).
 * A file whose title matches no form is left unread and named in the log.
 * Some pages only: the notices that begin on those pages of the issue's largest file are read, each to its end.
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const CHUNK = 100;
const FOLLOW = 40;

export interface LabelsRun { id: string; issue_id: string; object_key: string; container: string | null; from_page: number | null; to_page: number | null; spec: LabelsSpec }

/** The file copied with its tables of letters laid open (qpdf --qdf), then its Arabic put in the order it is read. */
export async function arabicOrder(pdf: string, out: string): Promise<{ changed: number }> {
  const q = await capture("qpdf", ["--qdf", "--object-streams=disable", pdf, out], 20 * 60 * 1000);
  if (q.code === 127) throw new Error("qpdf is not installed in this service");
  if (q.code !== 0 && q.code !== 3) throw new Error(`the file could not be prepared for reading: ${q.err.trim().slice(-300)}`);
  return { changed: await arabicOrderInPlace(out) };
}

async function words(pdf: string, from: number, to: number): Promise<LPage[]> {
  const t = await capture("pdftotext", ["-bbox", "-f", String(from), "-l", String(to), "-enc", "UTF-8", pdf, "-"], 20 * 60 * 1000);
  if (t.code === 127) throw new Error("pdftotext is not installed in this service");
  if (t.code !== 0) throw new Error(`pages ${from} to ${to} could not be read as text (pdftotext ended with code ${t.code}${t.err.trim() ? `: ${t.err.trim().slice(-160)}` : ""})`);
  const pages = pagesOf(t.out);
  if (pages.length !== to - from + 1) throw new Error(`pages ${from} to ${to}: ${pages.length} of ${to - from + 1} pages came back from the file's text`);
  return pages;
}

export async function runLabelsRun(conn: Db, r: LabelsRun, log: Log): Promise<void> {
  const id = r.id; const spec = r.spec;
  const q = <T>(query: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(query)) as unknown as T[]);
  const dir = path.join(os.tmpdir(), `meesam-run-${id}`);
  let marks = 0; let notices = 0;
  const end = async (status: "done" | "failed" | "stopped", error: string | null) => {
    await q(sql`UPDATE watch.read_run SET status = CASE WHEN status = 'stopped' THEN status ELSE ${status} END, error = COALESCE(error, ${error}),
      outcome = watch.fn_read_run_outcome(id), finished_at = COALESCE(finished_at, now()), updated_at = now() WHERE id = ${id}::uuid`);
    await rm(dir, { recursive: true, force: true });
    // where the source's settings say so, the complete marks need no person (Founder ruling 24 Nov 2026: the UAE starts with a person)
    if (status !== "failed") {
      const a = await q<{ n: number }>(sql`SELECT watch.fn_read_run_accept(${id}::uuid) AS n`).catch(() => []);
      log("info", "read_run.accepted", { id, accepted: Number(a[0]?.n ?? 0) });
    }
    if (marks > 0 && marks <= 300) await q(sql`SELECT platform.enqueue_job('watch.mark_pages', jsonb_build_object('issue_id', ${r.issue_id}::uuid), now(), ${`watch.mark_pages:${r.issue_id}`})`);
    log(status === "done" ? "info" : "error", `read_run.${status}`, { id, by: "labels", marks, notices, error });
  };
  const partDone = async (seq: number, result: Record<string, unknown>) =>
    q(sql`UPDATE watch.read_part SET status = 'done', attempts = attempts + 1, input_tokens = 0, output_tokens = 0, result = ${JSON.stringify({ ...result, by: "labels" })}::jsonb, error = NULL, updated_at = now()
      WHERE run_id = ${id}::uuid AND seq = ${seq}::int`);
  const store = async (f: FormSpec, file: string, got: Entry[], firstOfFile: boolean) => {
    if (f.kind === "marks") {
      const ms: LabelsMark[] = got.map((e) => markOf(e, f, file));
      await withRole(conn, "meesam_worker", async (tx) => { for (const m of ms) await tx.execute(sql`SELECT watch.fn_read_mark_store(${id}::uuid, ${JSON.stringify(m)}::jsonb)`); });
      marks += ms.length;
    } else {
      const ns: LabelsNotice[] = got.map((e) => noticeOf(e, f, file));
      await q(sql`SELECT watch.fn_read_notices_store(${id}::uuid, ${f.key}, ${JSON.stringify(ns)}::jsonb, ${firstOfFile}::boolean)`);
      notices += ns.length;
    }
  };
  try {
    const forms = formsOf(spec);
    if (forms.length === 0) throw new Error("This source's settings for reading by labels name no form.");
    await mkdir(dir, { recursive: true });
    const ranged = r.from_page !== null && r.to_page !== null;
    const originals = ranged ? [(await bringIssue(dir, r.object_key, r.container)).pdf] : await bringIssueAll(dir, r.object_key, r.container);

    // each file: prepared for reading where the settings ask for it, then told by the title on its first page
    const files: Array<{ name: string; pdf: string; copy: boolean; pages: number; form: FormSpec }> = [];
    const unread: string[] = [];
    for (let i = 0; i < originals.length; i++) {
      const original = originals[i]!; const name = path.basename(original);
      let pdf = original;
      if (spec.prepare === "arabic_order") { pdf = path.join(dir, `read-${i}.pdf`); await arabicOrder(original, pdf); }
      else if (spec.prepare) throw new Error(`This source's settings ask for a preparation that is not known: ${spec.prepare}`);
      const pages = (await cutPages(original, path.join(dir, "probe.pdf"), 1, 1)).pageCount;
      const form = formOf((await words(pdf, 1, 1))[0]!, forms);
      if (form) files.push({ name, pdf, copy: pdf !== original, pages, form }); else { unread.push(name); if (pdf !== original) await rm(pdf, { force: true }); }
    }
    if (unread.length) log("info", "read_run.files_unread", { id, files: unread.map((n) => n.slice(0, 120)) });
    if (files.length === 0) return await end("failed", "No file of this issue begins with a title that the source's settings know.");

    const parts: Array<{ kind: "entries"; from: number; to: number; file: number }> = [];
    files.forEach((f, i) => {
      const from = ranged ? Math.min(r.from_page!, f.pages) : 1; const to = ranged ? Math.min(r.to_page!, f.pages) : f.pages;
      for (let a = from; a <= to; a += CHUNK) parts.push({ kind: "entries", from: a, to: Math.min(to, a + CHUNK - 1), file: i });
    });
    await withRole(conn, "meesam_worker", async (tx) => {
      await tx.execute(sql`DELETE FROM watch.read_part WHERE run_id = ${id}::uuid`);
      await tx.execute(sql`INSERT INTO watch.read_part (run_id, seq, kind, from_page, to_page)
        SELECT ${id}::uuid, (x ->> 'seq')::int, x ->> 'kind', (x ->> 'from')::int, (x ->> 'to')::int FROM jsonb_array_elements(${JSON.stringify(parts.map((p, i) => ({ ...p, seq: i + 1 })))}::jsonb) x`);
      await tx.execute(sql`UPDATE watch.read_run SET status = 'reading', started_at = now(), file_name = ${(files.length === 1 ? files[0]!.name : `${files.length} files`).slice(0, 200)},
        page_count = ${files.reduce((n, f) => n + f.pages, 0)}::int, first_page = ${parts[0]!.from}::int, parts_total = ${parts.length}::int, updated_at = now() WHERE id = ${id}::uuid AND status = 'queued'`);
    });
    log("info", "read_run.planned", { id, by: "labels", files: files.map((f) => `${f.form.key}: ${f.pages} pages`), unread: unread.length, parts: parts.length });

    let entries = 0;
    for (let g = 0; g < files.length; g++) {
      const f = files[g]!;
      const reader = f.form.layout === "table" ? new TableReader(f.form) : new FormReader(f.form);
      const mine = parts.map((p, i) => ({ ...p, seq: i + 1 })).filter((p) => p.file === g);
      let first = true;
      for (const p of mine) {
        const state = (await q<{ status: string }>(sql`SELECT status FROM watch.read_run WHERE id = ${id}::uuid`))[0]?.status;
        if (state !== "reading") return await end("stopped", null);
        const got: Entry[] = [];
        (await words(f.pdf, p.from, p.to)).forEach((pg, i) => got.push(...reader.feed(pg, p.from + i)));
        const last = p === mine[mine.length - 1];
        if (last && !ranged) got.push(...reader.end_());
        if (last && ranged) {
          // the notice still open at the last asked page is followed to its end, and nothing after it is taken
          let closed = false;
          for (let a = p.to + 1; a <= Math.min(f.pages, p.to + FOLLOW) && !closed; a++) {
            const more = reader.feed((await words(f.pdf, a, a))[0]!, a);
            if (more.length) { got.push(more[0]!); closed = true; }
          }
          if (!closed) got.push(...reader.end_());
        }
        await store(f.form, f.name, got, first);
        await partDone(p.seq, { [f.form.kind]: got.length, part: f.form.key, file: f.name.slice(0, 200) });
        first = false; entries += got.length;
      }
      if (f.copy) await rm(f.pdf, { force: true });   // the copy made for reading is not kept
    }
    await q(sql`UPDATE watch.read_run SET entries_found = ${entries}::int, updated_at = now() WHERE id = ${id}::uuid`);
    return await end(entries > 0 ? "done" : "failed", entries > 0 ? null : "No notice was found on these pages.");
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    await end("failed", (err.cause?.message ? `${err.message}: ${err.cause.message}` : err.message).slice(0, 900));
  }
}
