import { createHash } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { putObjectFile, vaultConfig, withRole, type Db } from "@meesam/db";
import { contentTypeOf, discoverLinks, issueKey, shapeProblem, type ListedIssue, type SourceSpec } from "./discover.js";

/**
 * Watch, stage 1 — Fetch (MSM-PRD-02 Sections 3 and 4). For every source that is due: read its page, list the
 * issues, download the ones whose opposition window is still open, check each file's shape, store it once in the
 * publications bucket and record the run. A failure is recorded and retried with backoff by the database
 * (watch.fn_fetch_failed); after three in a row the staff get a "source broken" incident. Nobody uploads a file.
 *
 * Each database call is its own short transaction: a download can take minutes and must not hold one open,
 * and a failure must leave its record behind.
 */
interface DueSource { source_id: string; registry_code: string; stream: string; format: string; fetch_spec: SourceSpec; failures: number }
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const AGENT = "MeesamWatch/1.0 (+https://meesam.ae; publication fetcher)";
const rows = <T>(r: unknown) => r as unknown as T[];
const run = <T>(conn: Db, fn: (tx: Db) => Promise<T>) => withRole(conn, "meesam_worker", fn);
const message = (e: unknown) => { const x = e as Error & { cause?: Error }; return [x.message, x.cause?.message].filter(Boolean).join(" — ").slice(0, 400); };

async function readPage(url: string): Promise<string> {
  const res = await fetch(url, { headers: { "user-agent": AGENT, accept: "text/html,application/xhtml+xml" }, redirect: "follow", signal: AbortSignal.timeout(60_000) });
  if (!res.ok) throw new Error(`the page answered ${res.status}`);
  return await res.text();
}

/** Downloads to scratch space, hashing as it goes; returns the size, the checksum and the first bytes. */
async function download(url: string, file: string, maxBytes: number): Promise<{ bytes: number; sha256: string; head: Uint8Array }> {
  const res = await fetch(url, { headers: { "user-agent": AGENT }, redirect: "follow", signal: AbortSignal.timeout(20 * 60_000) });
  if (!res.ok || !res.body) throw new Error(`the file answered ${res.status}`);
  const hash = createHash("sha256");
  const out = createWriteStream(file);
  let bytes = 0;
  let head = new Uint8Array(0);
  try {
    for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
      if (head.length < 8) head = new Uint8Array([...head, ...chunk.subarray(0, 8 - head.length)]);
      bytes += chunk.length;
      if (bytes > maxBytes) throw new Error(`the file is larger than the ${maxBytes} bytes the catalogue allows`);
      hash.update(chunk);
      if (!out.write(chunk)) await new Promise<void>((r) => out.once("drain", () => r()));
    }
  } finally {
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
    if ((spec.fetcher ?? "page_crawler") !== "page_crawler") {
      log("info", "watch.fetch", { source: src.source_id, message: `fetcher type ${spec.fetcher} is not built yet` });
      continue;
    }
    // 1. discover
    let listed: ListedIssue[];
    try {
      listed = discoverLinks(await readPage(spec.url), spec);
      if (listed.length === 0) throw new Error("no issue links were found on the page (it may have moved or changed)");
    } catch (err) {
      await failed(null, "discover", err);
      log("error", "watch.fetch.discover", { registry: src.registry_code, stream: src.stream, message: message(err) });
      continue;
    }
    // 2. what is new and still inside its window (pages list newest first; the first twenty are enough to look at)
    const known = new Map(rows<{ issue_no: string; stored: boolean }>(await run(conn, (tx) => tx.execute(sql`SELECT * FROM watch.fn_fetch_known(${src.source_id}::uuid)`))).map((k) => [k.issue_no, k.stored]));
    const todo: ListedIssue[] = [];
    for (const issue of listed.slice(0, 20)) {
      if (known.get(issue.issueNo)) continue;
      const w = rows<{ wanted: boolean }>(await run(conn, (tx) => tx.execute(sql`SELECT watch.fn_fetch_wanted(${src.source_id}::uuid, ${issue.publishedOn}::date) AS wanted`)));
      if (w[0]?.wanted) todo.push(issue);
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
        const got = await download(issue.url, file, spec.max_bytes ?? 2 * 1024 * 1024 * 1024);
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
