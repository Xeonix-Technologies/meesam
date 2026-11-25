import { mkdir, readdir, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { putObject, vaultConfig, withRole, type Db, type Job } from "@meesam/db";
import { bringIssueAll } from "./read.js";
import { capture } from "./read-codes.js";
import { picturesIn, type PictureRule } from "./pictures.js";

/**
 * The picture of each published mark, cut out of the issue and kept beside it (Founder, 24 Nov 2026: first step
 * toward comparing marks as pictures). A bulletin made with a word processor holds each mark's picture as an image
 * of its own inside the file; it is taken out as it is (pdfimages), never redrawn from the page.
 *
 * Which image on a notice's pages is the mark: the largest one that is at least `min` pixels wide and high
 * and is not one of the office's own images (its emblem), whose sizes the source's settings name
 * (fetch_spec.read.picture, data). A notice without such an image keeps no picture, and nothing is guessed.
 * The job is safe to run again: only marks that have no picture yet are looked at, verified or not.
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const CHUNK = 100;

export async function runMarkPictures(conn: Db, job: Job, log: Log): Promise<void> {
  const issueId = String((job.payload as { issue_id?: string }).issue_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(issueId)) return;
  const q = <T>(query: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(query)) as unknown as T[]);
  const issue = (await q<{ object_key: string | null; container: string | null; rule: PictureRule | null }>(sql`
    SELECT i.object_key, i.container, s.fetch_spec -> 'read' -> 'picture' AS rule
      FROM watch.publication_issue i JOIN watch.publication_source s ON s.id = i.source_id WHERE i.id = ${issueId}::uuid`))[0];
  if (!issue?.object_key || !issue.rule) return;
  const marks = await q<{ id: string; page: number; page_to: number | null; file: string | null; part: string | null }>(sql`
    SELECT m.id, (m.extraction ->> 'page')::int AS page, CASE WHEN m.extraction ->> 'page_to' ~ '^[0-9]+$' THEN (m.extraction ->> 'page_to')::int END AS page_to,
           m.extraction ->> 'file' AS file, m.extraction ->> 'part' AS part
      FROM watch.published_mark m
     WHERE m.issue_id = ${issueId}::uuid AND m.extraction ->> 'page' ~ '^[0-9]+$' AND m.extraction ->> 'read_by' = 'labels' AND NOT (m.extraction ? 'image_key') ORDER BY 4, 2`);
  // the vectors follow the pictures, also for pictures cut out earlier (the picture service may have been switched on since)
  const queueEmbed = () => q(sql`SELECT platform.enqueue_job('watch.mark_embed', jsonb_build_object('issue_id', ${issueId}::uuid), now(), ${`watch.mark_embed:${issueId}:${job.id}`})`);
  if (marks.length === 0) { await queueEmbed(); return; }
  const dir = path.join(os.tmpdir(), `meesam-pictures-${issueId}`);
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });
  let done = 0; let none = 0;
  try {
    const files = await bringIssueAll(dir, issue.object_key, issue.container);
    const bucket = vaultConfig("PUBLICATIONS");
    const base = issue.object_key.replace(/\.[A-Za-z0-9]+$/, "");
    for (const pdf of files) {
      const mine = marks.filter((m) => (m.file ? m.file === path.basename(pdf) : files.length === 1));
      if (mine.length === 0) continue;
      const last = Math.max(...mine.map((m) => m.page_to ?? m.page));
      // the pictures of each stretch of pages, then the marks whose notice begins in it
      const found = new Map<number, { file: string; w: number; h: number }>();
      for (let a = 1; a <= last; a += CHUNK) {
        const b = Math.min(last, a + CHUNK - 1);
        if (!mine.some((m) => (m.page_to ?? m.page) >= a && m.page <= b)) continue;
        const list = await capture("pdfimages", ["-list", "-f", String(a), "-l", String(b), pdf], 20 * 60 * 1000);
        if (list.code === 127) throw new Error("pdfimages is not installed in this service");
        if (list.code !== 0) throw new Error(`the images of pages ${a} to ${b} could not be listed (pdfimages ended with code ${list.code})`);
        const want = picturesIn(list.out, issue.rule);
        if (want.size === 0) continue;
        const out = path.join(dir, `cut-${a}`);
        await mkdir(out, { recursive: true });
        const cut = await capture("pdfimages", ["-png", "-p", "-f", String(a), "-l", String(b), pdf, path.join(out, "x")], 30 * 60 * 1000);
        if (cut.code !== 0) throw new Error(`the images of pages ${a} to ${b} could not be taken out (pdfimages ended with code ${cut.code})`);
        const byNum = new Map<number, string>();
        for (const name of await readdir(out)) { const m = /-(\d+)\.png$/.exec(name); if (m) byNum.set(Number(m[1]), path.join(out, name)); }
        for (const [page, p] of want) { const f = byNum.get(p.num); if (f) found.set(page, { file: f, w: p.w, h: p.h }); }
        for (const m of mine) {
          if (m.page < a || m.page > b) continue;
          // the picture stands on the notice's first page; a notice that runs on may carry it on a later one in this stretch
          let pic: { file: string; w: number; h: number } | undefined; let at = m.page;
          for (let p = m.page; p <= Math.min(b, m.page_to ?? m.page) && !pic; p++) { pic = found.get(p); at = p; }
          if (!pic) { none += 1; continue; }
          try {
            const key = `${base}.marks/${m.part && /^[a-z0-9_]{1,40}$/.test(m.part) ? `${m.part}-` : ""}p${at}.png`;
            await putObject(bucket, key, await readFile(pic.file), "image/png");
            await q(sql`SELECT watch.fn_mark_picture_set(${issueId}::uuid, ${m.id}::uuid, ${key}, ${pic.w}::int, ${pic.h}::int)`);
            done += 1;
          } catch (e) {
            log("error", "mark_pictures.one", { issue: issueId, page: m.page, message: (e as Error).message.slice(0, 300) });
          }
        }
        found.clear();
        await rm(out, { recursive: true, force: true });
      }
    }
    log("info", "mark_pictures.done", { issue: issueId, marks: marks.length, stored: done, without_picture: none });
    await queueEmbed();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
