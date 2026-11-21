import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdtemp, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { deleteObject, putObjectFile, vaultConfig, withRole, type Db, type Job } from "@meesam/db";

/**
 * Second copy of the database (plan item A7; Founder ruling R15, 21 Nov 2026).
 * Each night the worker makes a full copy with PostgreSQL's own tool (pg_dump, custom format), checks that the
 * copy lists its contents, stores it in the BACKUP_* bucket (another company and region than the main system),
 * and applies the retention rule. About once a week, or when a system administrator asks, it also restores the
 * copy into a scratch database, compares it with the live one and drops it: a copy is only proven by restoring it.
 * Every run is recorded in platform.backup_run. Nothing is read from or written to the customers' documents here.
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const SCRATCH_DB = "meesam_restore_check";
const SCHEMAS = "'core','registry','watch','prospect','platform'";
const COUNTS_SQL = `SELECT json_build_object(
  'tables', (SELECT count(*) FROM pg_tables WHERE schemaname IN (${SCHEMAS})),
  'accounts', (SELECT count(*) FROM core.account),
  'records', (SELECT count(*) FROM core.record),
  'issues', (SELECT count(*) FROM watch.publication_issue))`;

export interface Counts { tables: number; accounts: number; records: number; issues: number }

/** Connection settings for the PostgreSQL tools, passed in the environment so the password never appears in a command line. */
export function pgEnv(url: string, database?: string): NodeJS.ProcessEnv {
  const u = new URL(url);
  const env: NodeJS.ProcessEnv = {
    PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8",
    PGHOST: u.hostname, PGPORT: u.port || "5432", PGUSER: decodeURIComponent(u.username), PGPASSWORD: decodeURIComponent(u.password),
    PGDATABASE: database ?? decodeURIComponent(u.pathname.replace(/^\//, "")), PGCONNECT_TIMEOUT: "30",
  };
  const ssl = u.searchParams.get("sslmode");
  if (ssl) env.PGSSLMODE = ssl;
  return env;
}

export function run(cmd: string, args: string[], env: NodeJS.ProcessEnv, timeoutMs = 60 * 60 * 1000): Promise<{ code: number; out: string; err: string }> {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    p.stdout.on("data", (d: Buffer) => { if (out.length < 4_000_000) out += d.toString(); });
    p.stderr.on("data", (d: Buffer) => { if (err.length < 20_000) err += d.toString(); });
    const timer = setTimeout(() => { err += `\n${cmd} stopped after ${Math.round(timeoutMs / 60000)} minutes`; p.kill("SIGKILL"); }, timeoutMs);
    p.on("error", (e) => { clearTimeout(timer); resolve({ code: 127, out, err: `${cmd}: ${e.message}` }); });
    p.on("close", (code) => { clearTimeout(timer); resolve({ code: code ?? 1, out, err }); });
  });
}

const tail = (s: string, n = 600) => s.trim().split("\n").slice(-6).join(" | ").slice(-n);

export async function counts(env: NodeJS.ProcessEnv): Promise<Counts> {
  const r = await run("psql", ["-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", COUNTS_SQL], env, 5 * 60 * 1000);
  if (r.code !== 0) throw new Error(`reading the counts failed: ${tail(r.err)}`);
  return JSON.parse(r.out.trim()) as Counts;
}

async function fileHash(file: string): Promise<string> {
  const h = createHash("sha256");
  for await (const chunk of createReadStream(file)) h.update(chunk as Buffer);
  return h.digest("hex");
}

/** Make the copy and check that it lists its contents. Returns its size, checksum and number of entries. */
export async function dumpTo(dbUrl: string, file: string): Promise<{ bytes: number; sha256: string; entries: number }> {
  const env = pgEnv(dbUrl);
  const d = await run("pg_dump", ["--format=custom", "--compress=6", "--no-password", `--file=${file}`], env);
  if (d.code === 127) throw new Error("pg_dump is not installed in this service");
  if (d.code !== 0) throw new Error(`pg_dump failed: ${tail(d.err)}`);
  const l = await run("pg_restore", ["--list", file], env, 10 * 60 * 1000);
  if (l.code !== 0) throw new Error(`the copy cannot be read back: ${tail(l.err)}`);
  const entries = l.out.split("\n").filter((x) => x.trim() && !x.startsWith(";")).length;
  if (entries < 50) throw new Error(`the copy lists only ${entries} objects`);
  const bytes = (await stat(file)).size;
  return { bytes, sha256: await fileHash(file), entries };
}

/**
 * Restore the copy into a scratch database on the same server, compare it with the live counts taken just before
 * and just after the copy was made, and drop it. The live database is only read.
 */
export async function restoreTest(dbUrl: string, file: string, before: Counts, after: Counts): Promise<{ ok: boolean; detail: Record<string, unknown> }> {
  const live = pgEnv(dbUrl);
  const scratch = pgEnv(dbUrl, SCRATCH_DB);
  const started = Date.now();
  const sqlOn = (env: NodeJS.ProcessEnv, q: string) => run("psql", ["-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", q], env, 10 * 60 * 1000);
  try {
    await sqlOn(live, `DROP DATABASE IF EXISTS ${SCRATCH_DB} WITH (FORCE)`);
    const c = await sqlOn(live, `CREATE DATABASE ${SCRATCH_DB}`);
    if (c.code !== 0) return { ok: false, detail: { error: `the scratch database could not be created: ${tail(c.err)}` } };
    const r = await run("pg_restore", ["--no-owner", "--no-password", `--dbname=${SCRATCH_DB}`, file], scratch);
    const restored = await counts(scratch);
    const within = (k: keyof Counts) => restored[k] >= Math.min(before[k], after[k]) && restored[k] <= Math.max(before[k], after[k]);
    const same = restored.tables === after.tables && within("accounts") && within("records") && within("issues");
    return { ok: r.code === 0 && same, detail: { counts: { before, after, restored }, seconds: Math.round((Date.now() - started) / 1000), ...(r.code !== 0 ? { error: tail(r.err) } : {}), ...(same ? {} : { mismatch: true }) } };
  } catch (e) {
    return { ok: false, detail: { error: (e as Error).message } };
  } finally {
    await sqlOn(live, `DROP DATABASE IF EXISTS ${SCRATCH_DB} WITH (FORCE)`);
  }
}

let toldNotConfigured = false;

export async function runBackup(conn: Db, job: Job, log: Log): Promise<void> {
  const payload = (job.payload ?? {}) as { requested?: boolean; restore_test?: boolean; by?: string };
  const asWorker = <T>(q: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(q)) as unknown as T[]);
  if (!payload.requested) {
    const due = await asWorker<{ due: boolean }>(sql`SELECT platform.fn_backup_due(${Number(process.env.BACKUP_HOUR_UTC ?? 22)}::int) AS due`);
    if (!due[0]?.due) return;
  }
  const dbUrl = process.env.DATABASE_URL;
  let bucket;
  try { bucket = vaultConfig("BACKUP"); } catch { bucket = null; }
  if (!bucket || !dbUrl) {
    if (payload.requested) {
      await asWorker(sql`INSERT INTO platform.backup_run (finished_at, ok, trigger, requested_by, error) VALUES (now(), false, 'requested', ${payload.by ?? null}::uuid, 'The BACKUP_* variables are not set on the worker service')`);
    } else if (!toldNotConfigured) {
      toldNotConfigured = true;
      log("info", "backup.skip", { message: "BACKUP_* variables not set on the worker; no second copy is made" });
    }
    return;
  }
  const row = await asWorker<{ id: string }>(sql`INSERT INTO platform.backup_run (trigger, requested_by) VALUES (${payload.requested ? "requested" : "nightly"}, ${payload.by ?? null}::uuid) RETURNING id`);
  const id = row[0]!.id;
  const dir = await mkdtemp(path.join(os.tmpdir(), "meesam-backup-"));
  const file = path.join(dir, "db.dump");
  try {
    const env = pgEnv(dbUrl);
    const before = await counts(env);
    const made = await dumpTo(dbUrl, file);
    const after = await counts(env);
    const now = new Date();
    const stamp = now.toISOString().replace(/[-:]|\.\d{3}/g, "");
    const key = `db/${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, "0")}/meesam-${stamp}.dump`;
    await putObjectFile(bucket, key, file, made.bytes, made.sha256, "application/octet-stream");
    await asWorker(sql`UPDATE platform.backup_run SET object_key = ${key}, bytes = ${made.bytes}::bigint, sha256 = ${made.sha256}, entries = ${made.entries}::int, updated_at = now() WHERE id = ${id}::uuid`);

    // a restore test when asked for, otherwise when none has succeeded in the last seven days
    let test: { ok: boolean; detail: Record<string, unknown> } | null = null;
    const weekly = await asWorker<{ recent: boolean }>(sql`SELECT EXISTS (SELECT 1 FROM platform.backup_run WHERE restore_ok AND started_at > now() - interval '7 days') AS recent`);
    if (process.env.BACKUP_RESTORE_TEST !== "off" && (payload.restore_test || (!payload.requested && !weekly[0]?.recent))) {
      test = await restoreTest(dbUrl, file, before, after);
    }
    await asWorker(sql`UPDATE platform.backup_run SET finished_at = now(), ok = true, restore_ok = ${test ? test.ok : null}::boolean, restore = ${test ? JSON.stringify(test.detail) : null}::jsonb, updated_at = now() WHERE id = ${id}::uuid`);
    log("info", "backup.done", { key, bytes: made.bytes, entries: made.entries, restore: test ? test.ok : "not run" });

    const old = await asWorker<{ id: string; object_key: string }>(sql`SELECT * FROM platform.fn_backup_expire(${Number(process.env.BACKUP_KEEP_DAYS ?? 35)}::int)`);
    for (const o of old) await deleteObject(bucket, o.object_key).catch((e: Error) => log("error", "backup.expire", { key: o.object_key, message: e.message }));
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    const raw = err.cause?.message ?? err.message;
    // the storage's own refusals, said plainly for the Backups page
    const hint = /AccessDenied/.test(raw) ? "The storage refused the upload: this access key may not write to the bucket named in BACKUP_BUCKET. Check that the key's permission is Object Read & Write, that it is limited to that same bucket, and that the bucket name is spelled exactly. "
      : /SignatureDoesNotMatch|InvalidAccessKeyId|Unauthorized/.test(raw) ? "The storage did not accept the access key: check BACKUP_ACCESS_KEY_ID and BACKUP_SECRET_ACCESS_KEY for a missing or extra character. "
      : /NoSuchBucket/.test(raw) ? "The storage has no bucket with the name in BACKUP_BUCKET at the address in BACKUP_ENDPOINT. " : "";
    const message = (hint + raw).slice(0, 900);
    await asWorker(sql`UPDATE platform.backup_run SET finished_at = now(), ok = false, error = ${message}, updated_at = now() WHERE id = ${id}::uuid`);
    throw e;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
