import http from "node:http";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { createDb, migrate, withRole, type Db, type Job } from "@meesam/db";

/**
 * Meesam worker — job-table runner (Data Architecture 14.11, Ruled).
 * Jobs are claimed with platform.claim_jobs() (SELECT … FOR UPDATE SKIP LOCKED) as meesam_worker.
 * Handlers register by kind; Step 3 adds them: timers and notifications (3.6), pricing batches (3.7),
 * watch fetch → extract → verify → compare → alert (3.8), prospects (3.9).
 */
type Handler = (db: Db, job: Job) => Promise<void>;

const handlers: Record<string, Handler> = {
  // Nightly housekeeping: partitions ahead, stale running jobs back to the queue.
  "platform.housekeeping": async (db) => {
    await db.execute(sql`SELECT platform.ensure_month_partitions('platform', 'audit_event', 12)`);
    await db.execute(sql`SELECT platform.ensure_month_partitions('platform', 'telemetry_event', 3)`);
    await db.execute(sql`SELECT platform.ensure_year_partitions('watch', 'candidate', 1)`);
    await db.execute(sql`SELECT watch.ensure_published_mark_partitions(id, 1) FROM registry.registry`);
    await db.execute(sql`SELECT platform.requeue_stale_jobs(interval '30 minutes')`);
    // schedule the next run (dedupe key keeps exactly one queued)
    await db.execute(sql`SELECT platform.enqueue_job('platform.housekeeping', '{}'::jsonb, date_trunc('day', now()) + interval '1 day 1 hour', 'platform.housekeeping')`);
  },
};

const port = Number(process.env.PORT ?? 8080);
const pollMs = Number(process.env.WORKER_POLL_MS ?? 5000);
const batch = Number(process.env.WORKER_BATCH ?? 5);
const workerId = `${os.hostname()}:${process.pid}`;
let ticks = 0;
let processed = 0;
let failed = 0;
let stopping = false;
let db: Db | null = null;

function log(level: "info" | "error", at: string, extra: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ level, at, worker: workerId, ...extra });
  if (level === "error") console.error(line);
  else console.log(line);
}

async function runJob(conn: Db, job: Job): Promise<void> {
  const handler = handlers[job.kind];
  if (!handler) {
    await withRole(conn, "meesam_worker", (tx) => tx.execute(sql`SELECT platform.fail_job(${job.id}::uuid, ${"no handler for kind " + job.kind})`));
    failed += 1;
    return;
  }
  try {
    // the handler runs as meesam_worker in one transaction; completion is recorded in a second one
    await withRole(conn, "meesam_worker", (tx) => handler(tx, job));
    await withRole(conn, "meesam_worker", (tx) => tx.execute(sql`SELECT platform.complete_job(${job.id}::uuid)`));
    processed += 1;
  } catch (err) {
    failed += 1;
    const message = cause(err);
    log("error", "job.failed", { kind: job.kind, id: job.id, message });
    await withRole(conn, "meesam_worker", (tx) => tx.execute(sql`SELECT platform.fail_job(${job.id}::uuid, ${message})`));
  }
}

async function tick(): Promise<void> {
  ticks += 1;
  if (!db) return;
  const conn = db;
  const claimed = await withRole(conn, "meesam_worker", (tx) => tx.execute(sql`SELECT * FROM platform.claim_jobs(${workerId}, ${batch}::int)`));
  const rows = claimed as unknown as Array<Record<string, unknown>>;
  for (const row of rows) {
    const job = {
      id: row.id,
      kind: row.kind,
      payload: row.payload,
      status: row.status,
      runAt: row.run_at,
      priority: row.priority,
      attempts: row.attempts,
      maxAttempts: row.max_attempts,
      lockedAt: row.locked_at,
      lockedBy: row.locked_by,
      finishedAt: row.finished_at,
      lastError: row.last_error,
      dedupeKey: row.dedupe_key,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    } as Job;
    await runJob(conn, job);
  }
}

async function loop(): Promise<void> {
  while (!stopping) {
    try {
      await tick();
    } catch (err) {
      log("error", "worker.tick", { message: cause(err) });
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}

function cause(err: unknown): string {
  const e = err as Error & { cause?: Error };
  return [e.message, e.cause?.message].filter(Boolean).join(" — ");
}

/**
 * Start-up: apply pending migrations (idempotent; advisory-locked, so a pre-deploy run and this
 * run never conflict), then seed the housekeeping job. A database that is not ready yet is
 * retried every 15 s rather than crashing the service; /health reports db:false meanwhile.
 */
async function boot(): Promise<void> {
  const url = process.env.DATABASE_URL;
  if (!url) {
    log("info", "worker.db", { connected: false, message: "DATABASE_URL not set; idling" });
    return;
  }
  const migrationsDir = process.env.MIGRATIONS_DIR ?? path.resolve(process.cwd(), "migrations");
  for (let attempt = 1; ; attempt++) {
    try {
      const applied = await migrate({ url, dir: migrationsDir, log: (line) => log("info", "migrate", { message: line }) });
      if (applied.length > 0) log("info", "migrate.applied", { applied });
      const conn = createDb("direct");
      await withRole(conn, "meesam_worker", (tx) =>
        tx.execute(sql`SELECT platform.enqueue_job('platform.housekeeping', '{}'::jsonb, now(), 'platform.housekeeping')`),
      );
      db = conn;
      log("info", "worker.db", { connected: true, attempt });
      return;
    } catch (err) {
      log("error", "worker.boot", { attempt, message: cause(err) });
      await new Promise((r) => setTimeout(r, 15_000));
    }
  }
}

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        status: "ok",
        service: "worker",
        ticks,
        processed,
        failed,
        db: db !== null,
        environment: process.env.RAILWAY_ENVIRONMENT_NAME ?? "local",
      }),
    );
    return;
  }
  res.writeHead(404).end();
});

server.listen(port, () => log("info", "worker.start", { port, pollMs, batch }));
void loop();
void boot();

for (const sig of ["SIGTERM", "SIGINT"] as const) {
  process.on(sig, () => {
    stopping = true;
    server.close(() => process.exit(0));
  });
}
