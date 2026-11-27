import { createHash } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { putObjectFile, vaultConfig, withRole, type Db } from "@meesam/db";
import { get } from "./get.js";
import { relayFor, type Relay } from "./relay.js";
import { contentTypeOf, countMatchingLinks, discoverLinks, listLinks, issueKey, patternCandidates, shapeProblem, type ListedIssue, type PatternSpec, type SourceSpec } from "./discover.js";

/**
 * Watch, stage 1 — Fetch (MSM-PRD-02 Sections 3 and 4). For every source that is due: read its page, list the
 * issues, download the ones whose opposition window is still open, check each file's shape, store it once in the
 * publications bucket and record the run. A failure is recorded and retried with backoff by the database
 * (watch.fn_fetch_failed); after three in a row the staff get a "source broken" incident. Nobody uploads a file.
 *
 * Each database call is its own short transaction: a download can take minutes and must not hold one open,
 * and a failure must leave its record behind.
 */
interface DueSource { source_id: string; registry_code: string; stream: string; format: string; fetch_spec: SourceSpec & PatternSpec; failures: number }
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const rows = <T>(r: unknown) => r as unknown as T[];
const run = <T>(conn: Db, fn: (tx: Db) => Promise<T>) => withRole(conn, "meesam_worker", fn);
const message = (e: unknown) => { const x = e as Error & { cause?: Error }; return [x.message, x.cause?.message].filter(Boolean).join(" — ").slice(0, 400); };

async function readPage(url: string, via: Relay | null = null): Promise<string> {
  const res = await get(url, { accept: "text/html,application/xhtml+xml", connectMs: 45_000, idleMs: 120_000, via });   // some registry sites take over a minute to answer
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of res as AsyncIterable<Buffer>) { size += c.length; if (size > 20 * 1024 * 1024) throw new Error("the page is larger than 20 MB"); chunks.push(c); }
  return Buffer.concat(chunks).toString("utf8");
}

/** Downloads to scratch space, hashing as it goes; returns the size, the checksum and the first bytes. */
async function download(url: string, file: string, maxBytes: number, via: Relay | null = null): Promise<{ bytes: number; sha256: string; head: Uint8Array }> {
  const res = await get(url, { connectMs: 45_000, idleMs: 120_000, via });
  // one file never takes the worker for more than half an hour
  const cap = setTimeout(() => res.destroy(new Error("the download took longer than 30 minutes")), 30 * 60_000);
  const hash = createHash("sha256");
  const out = createWriteStream(file);
  let bytes = 0;
  let head = new Uint8Array(0);
  try {
    for await (const chunk of res as AsyncIterable<Buffer>) {
      if (head.length < 8) head = new Uint8Array([...head, ...chunk.subarray(0, 8 - head.length)]);
      bytes += chunk.length;
      if (bytes > maxBytes) throw new Error(`the file is larger than the ${maxBytes} bytes the catalogue allows`);
      hash.update(chunk);
      if (!out.write(chunk)) await new Promise<void>((r) => out.once("drain", () => r()));
    }
  } finally {
    clearTimeout(cap);
    await new Promise<void>((r) => out.end(() => r()));
  }
  return { bytes, sha256: hash.digest("hex"), head };
}

export async function runWatchFetch(conn: Db, log: Log): Promise<void> {
  let bucket;
  try {
    bucket = vaultConfig("PUBLICATIONS");
  } catch {
    // without the bucket nothing is polled, so nothing is marked failed; it starts by itself once the variables are set
    log("info", "watch.fetch", { message: "PUBLICATIONS_* bucket variables are not set on the worker; publications are not fetched yet" });
    return;
  }
  const due = rows<DueSource>(await run(conn, (tx) => tx.execute(sql`SELECT * FROM watch.fn_fetch_due()`)));
  for (const src of due) {
    const spec = src.fetch_spec;
    const failed = (issue: ListedIssue | null, step: string, err: unknown) =>
      run(conn, (tx) => tx.execute(sql`SELECT watch.fn_fetch_failed(${src.source_id}::uuid, ${issue?.issueNo ?? null}, ${issue?.publishedOn ?? null}::date, ${issue?.url ?? spec.url}, ${step}, ${message(err)})`));
    const fetcher = spec.fetcher ?? "page_crawler";
    if (fetcher !== "page_crawler" && fetcher !== "pattern") {
      log("info", "watch.fetch", { source: src.source_id, message: `fetcher type ${fetcher} is not built yet` });
      continue;
    }
    // a source that names a relay is fetched through it, or not at all (never directly instead)
    let via: Relay | null = null;
    try { via = relayFor((spec as { via?: string }).via); } catch (err) { await failed(null, "relay", err); log("error", "watch.fetch", { registry: src.registry_code, message: message(err) }); continue; }
    const known = new Map(rows<{ issue_no: string; stored: boolean }>(await run(conn, (tx) => tx.execute(sql`SELECT * FROM watch.fn_fetch_known(${src.source_id}::uuid)`))).map((k) => [k.issue_no, k.stored]));
    if (fetcher === "page_crawler" && spec.list_only) {
      // profiling a new registry: read the page and show the staff what it links to; nothing is downloaded
      try {
        const found = listLinks(await readPage(spec.url, via), spec, Math.min(Math.max(spec.list_limit ?? 40, 1), 200));
        await run(conn, async (tx) => {
          await tx.execute(sql`INSERT INTO watch.fetch_run (source_id, finished_at, outcome, detail)
            VALUES (${src.source_id}::uuid, now(), 'not_yet_published', ${JSON.stringify({ listing: true, total: found.total, links: found.links })}::jsonb)`);
          await tx.execute(sql`SELECT watch.fn_fetch_polled(${src.source_id}::uuid, ${found.total}::int, 1)`);
        });
        log("info", "watch.fetch.listing", { registry: src.registry_code, links: found.total });
      } catch (err) {
        await failed(null, "discover", err);
        log("error", "watch.fetch.discover", { registry: src.registry_code, stream: src.stream, message: message(err) });
      }
      continue;
    }
    let listed: ListedIssue[];
    const todo: ListedIssue[] = [];
    if (fetcher === "pattern") {
      // numbered addresses: no page is read; ask for the starting issue, then for the number after the newest held
      listed = patternCandidates(spec, [...known].filter(([, stored]) => stored).map(([no]) => no));
      if (listed.length === 0) { await failed(null, "discover", new Error("the catalogue row has no usable pattern and starting issue")); continue; }
      todo.push(...listed.filter((i) => !known.get(i.issueNo)));
    } else {
      // 1. discover
      try {
        const page = await readPage(spec.url, via);
        listed = discoverLinks(page, spec);
        if (listed.length === 0) {
          // say which half failed: no link has the expected address, or links were found but none names its issue
          const links = countMatchingLinks(page, spec);
          throw new Error(links === 0
            ? "no issue links were found on the page (it may have moved or changed)"
            : `${links} publication link(s) were found on the page, but none could be matched to an issue number`);
        }
      } catch (err) {
        await failed(null, "discover", err);
        log("error", "watch.fetch.discover", { registry: src.registry_code, stream: src.stream, message: message(err) });
        continue;
      }
      // 2. what is new and still inside its window (pages list newest first; the first twenty are enough to look at)
      for (const [i, issue] of listed.slice(0, 20).entries()) {
        if (known.get(issue.issueNo)) continue;
        // an unverified opposition period gives no window to judge by: the catalogue says how many of the newest
        // issues to hold, and nothing else on the page is taken
        if (spec.take_latest !== undefined) { if (i < spec.take_latest) todo.push(issue); continue; }
        const w = rows<{ wanted: boolean }>(await run(conn, (tx) => tx.execute(sql`SELECT watch.fn_fetch_wanted(${src.source_id}::uuid, ${issue.publishedOn}::date) AS wanted`)));
        if (w[0]?.wanted) todo.push(issue);
      }
    }
    await run(conn, (tx) => tx.execute(sql`SELECT watch.fn_fetch_polled(${src.source_id}::uuid, ${listed.length}::int, ${todo.length}::int)`));
    // 3. download, check, store — oldest first, so the window closest to its end is served first
    const container = (spec.container ?? "pdf").toLowerCase();
    let stored = 0;
    for (const issue of todo.reverse().slice(0, Math.max(1, spec.max_per_run ?? 3))) {
      const dir = await mkdtemp(path.join(os.tmpdir(), "msm-issue-"));
      const file = path.join(dir, "issue");
      let step = "download";
      try {
        const got = await download(issue.url, file, spec.max_bytes ?? 2 * 1024 * 1024 * 1024, via);
        step = "shape";
        const problem = shapeProblem(got.head, got.bytes, issue.publishedOn, spec);
        if (problem) throw new Error(problem);
        step = "store";
        const key = issueKey(src.registry_code, src.stream, issue.issueNo, got.sha256, container);
        await putObjectFile(bucket, key, file, got.bytes, got.sha256, contentTypeOf(container));
        step = "record";
        await run(conn, (tx) => tx.execute(sql`SELECT watch.fn_fetch_stored(${src.source_id}::uuid, ${issue.issueNo}, ${issue.publishedOn}::date, ${issue.url}, ${issue.title},
          ${key}, decode(${got.sha256}, 'hex'), ${got.bytes}::bigint, ${container})`));
        stored += 1;
      } catch (err) {
        // the next number of a pattern source is not published yet: the normal answer, tried again at the next poll
        if (issue.probe && step === "download" && /answered 404/.test(message(err))) continue;
        await failed(issue, step, err);
        log("error", "watch.fetch.issue", { registry: src.registry_code, issue: issue.issueNo, step, message: message(err) });
        break;      // the source is retried after the backoff; the remaining issues wait for that
      } finally {
        await rm(dir, { recursive: true, force: true });
      }
    }
    log("info", "watch.fetch.run", { registry: src.registry_code, stream: src.stream, listed: listed.length, wanted: todo.length, stored });
  }
}
