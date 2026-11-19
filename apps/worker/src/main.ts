import http from "node:http";
import os from "node:os";
import path from "node:path";
import { sql } from "drizzle-orm";
import { createDb, migrate, withRole, type Db, type Job } from "@meesam/db";
import { mailConfigured, sendDigestMail, sendReminderMail, type DigestRow, type ReminderMail } from "./mail.js";
import { runWatchFetch } from "./watch/fetch.js";

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
    await db.execute(sql`SELECT core.fn_sweep_intake_drafts(interval '30 days')`);
  },
  // Deadline reminders (System Description 4.11): work out the reminder points that fell due, then send their e-mails.
  // Both steps are idempotent; a point is notified once however often this runs.
  "notifications.reminders": async (db) => {
    const made = (await db.execute(sql`SELECT core.fn_reminders_materialise() AS n`)) as unknown as Array<{ n: number }>;
    // escalation (4.11): a hard deadline nobody in an account acknowledged is re-sent marked "unacknowledged" at 7 and 3 days
    const esc = (await db.execute(sql`SELECT core.fn_reminders_escalate() AS n`)) as unknown as Array<{ n: number }>;
    let sent = 0;
    let bad = 0;
    if (!mailConfigured()) {
      // without the mail token the reminders stay queued, so nothing is lost when it is set later
      log("info", "reminders.mail", { message: "EMAIL_PROVIDER_KEY not set on the worker; reminder e-mails stay queued", written: Number(made[0]?.n ?? 0) });
      return;
    }
    for (let round = 0; round < 8; round++) {
      const batchRows = (await db.execute(sql`SELECT * FROM platform.fn_reminder_mails_take(25)`)) as unknown as ReminderMail[];
      if (batchRows.length === 0) break;
      for (const m of batchRows) {
        try {
          await sendReminderMail(m);
          sent += 1;
        } catch (err) {
          bad += 1;
          await db.execute(sql`SELECT platform.fn_notification_failed(${m.id}::uuid, ${cause(err)})`);
        }
      }
    }
    // The daily summary (4.11): once a day after DIGEST_HOUR_UTC (default 04:00 UTC, 08:00 in the Gulf), one e-mail per user
    // with the Important reminders they chose to receive there and the trademarks the other side changed.
    const hour = Number(process.env.DIGEST_HOUR_UTC ?? 4);
    const digest = (await db.execute(sql`SELECT * FROM platform.fn_digest_take(now(), ${hour}::int)`)) as unknown as DigestRow[];
    const perUser = new Map<string, DigestRow[]>();
    for (const r of digest) perUser.set(r.user_id, [...(perUser.get(r.user_id) ?? []), r]);
    let summaries = 0;
    for (const list of perUser.values()) {
      try {
        await sendDigestMail(list);
        summaries += 1;
      } catch (err) {
        bad += 1;
        log("error", "digest.mail", { user: list[0]?.user_id, message: cause(err) });
      }
    }
    log("info", "reminders.run", { written: Number(made[0]?.n ?? 0), escalated: Number(esc[0]?.n ?? 0), sent, summaries, failed: bad });
  },
};

/**
 * Jobs that talk to the outside world for minutes (downloads). They get the connection, not a transaction, and
 * make their own short transactions, so nothing is held open and a failure leaves its record behind.
 */
const longHandlers: Record<string, Handler> = {
  // Watch, stage 1: poll the publication sources that are due and fetch new issues (MSM-PRD-02 Section 4).
  "watch.fetch": async (conn) => runWatchFetch(conn, log),
};

/**
 * Recurring jobs. The worker queues each one when its interval has passed; the dedupe key keeps a single
 * queued or running copy across replicas. (A job cannot queue its own next run: its dedupe key is still
 * taken while it runs, which is why housekeeping used to run only once per start.)
 */
const schedule: Array<{ kind: string; everyMs: number; last: number }> = [
  { kind: "platform.housekeeping", everyMs: 24 * 60 * 60 * 1000, last: 0 },
  { kind: "notifications.reminders", everyMs: Number(process.env.REMINDERS_EVERY_MS ?? 60 * 60 * 1000), last: 0 },
  // the job looks every two minutes (one small query when nothing is due); each source carries its own next poll
  // time (hourly for on-demand registries), and a staff "Poll now" queues the job at once (migration 0042)
  { kind: "watch.fetch", everyMs: Number(process.env.WATCH_FETCH_EVERY_MS ?? 2 * 60 * 1000), last: 0 },
];
async function queueDue(conn: Db): Promise<void> {
  const now = Date.now();
  for (const s of schedule) {
    if (now - s.last < s.everyMs) continue;
    await withRole(conn, "meesam_worker", (tx) => tx.execute(sql`SELECT platform.enqueue_job(${s.kind}, '{}'::jsonb, now(), ${s.kind})`));
    s.last = now;
  }
}

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
  const long = longHandlers[job.kind];
  const handler = handlers[job.kind];
  if (!handler && !long) {
    await withRole(conn, "meesam_worker", (tx) => tx.execute(sql`SELECT platform.fail_job(${job.id}::uuid, ${"no handler for kind " + job.kind})`));
    failed += 1;
    return;
  }
  try {
    // the handler runs as meesam_worker in one transaction; completion is recorded in a second one
    if (long) await long(conn, job);
    else await withRole(conn, "meesam_worker", (tx) => handler!(tx, job));
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
  await queueDue(conn);
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
      db = conn;   // the recurring jobs are queued by the first tick (queueDue)
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
