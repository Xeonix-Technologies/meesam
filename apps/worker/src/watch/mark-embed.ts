import { sql } from "drizzle-orm";
import { getObject, vaultConfig, withRole, type Db, type Job } from "@meesam/db";

/**
 * The vector of each published mark's picture (migration 0090; Founder ruling 25 Nov 2026: SigLIP 2 alone to
 * begin with). The picture cut out of the bulletin is sent to the embeddings service inside the project's private
 * network (EMBEDDINGS_URL), and the vector it returns is kept beside the mark with the engine that made it.
 * Nothing is compared here.
 *
 * Without EMBEDDINGS_URL the job does nothing and says so once: an environment without the picture service
 * (production, until it is switched on there) is not an error. The job works through a few hundred marks and
 * queues itself again while more are waiting, so one large bulletin does not hold a worker for long.
 */
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const BATCH = 300;

export async function runMarkEmbed(conn: Db, job: Job, log: Log): Promise<void> {
  const payload = job.payload as { issue_id?: string; round?: number };
  const issueId = String(payload.issue_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(issueId)) return;
  const base = (process.env.EMBEDDINGS_URL ?? "").trim().replace(/\/+$/, "");
  if (!/^https?:\/\/[^\s/]+/.test(base)) { log("info", "mark_embed.off", { issue: issueId, reason: "EMBEDDINGS_URL is not set" }); return; }
  const q = <T>(query: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(query)) as unknown as T[]);
  const marks = await q<{ id: string; key: string }>(sql`
    SELECT m.id, m.extraction ->> 'image_key' AS key FROM watch.published_mark m
     WHERE m.issue_id = ${issueId}::uuid AND m.extraction ? 'image_key' AND m.siglip_embedding IS NULL AND NOT (m.extraction ? 'embed_failed')
     ORDER BY m.id LIMIT ${BATCH + 1}`);
  if (marks.length === 0) return;
  // the service may still be starting (it loads its model first): asked once before the work begins
  const health = await fetch(`${base}/health`, { signal: AbortSignal.timeout(20_000) }).then((r) => r.json() as Promise<{ models_loaded?: boolean; error?: string | null }>).catch((e: Error) => ({ models_loaded: false, error: e.message }));
  if (!health.models_loaded) throw new Error(`the picture service is not ready: ${String(health.error ?? "its model is not loaded yet").slice(0, 200)}`);
  const bucket = vaultConfig("PUBLICATIONS");
  let done = 0; let failed = 0; const started = Date.now();
  for (const m of marks.slice(0, BATCH)) {
    try {
      const obj = await getObject(bucket, m.key);
      const res = await fetch(`${base}/embed`, {
        method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(120_000),
        body: JSON.stringify({ kind: "image", model: "siglip2", payload: obj.body.toString("base64") }),
      });
      if (res.status === 422) {
        // a picture the service cannot open is noted on the mark and not asked again
        await q(sql`SELECT watch.fn_mark_embedding_failed(${issueId}::uuid, ${m.id}::uuid, ${(await res.text()).slice(0, 200)})`);
        failed += 1; continue;
      }
      if (!res.ok) throw new Error(`the picture service answered ${res.status}: ${(await res.text()).slice(0, 200)}`);
      const r = (await res.json()) as { dim: number; vector: number[]; engine: string; phash: string | null };
      if (r.dim !== 768 || !Array.isArray(r.vector) || r.vector.length !== 768 || !r.vector.every((x) => Number.isFinite(x))) throw new Error("the picture service returned a vector of another shape");
      await q(sql`SELECT watch.fn_mark_embedding_set(${issueId}::uuid, ${m.id}::uuid, 'siglip2', ${`[${r.vector.join(",")}]`}, ${r.engine}, ${r.phash})`);
      done += 1;
    } catch (e) {
      // the service or the bucket not answering stops this round; the job is tried again by the queue
      log("error", "mark_embed.stopped", { issue: issueId, stored: done, message: (e as Error).message.slice(0, 300) });
      throw e;
    }
  }
  log("info", "mark_embed.done", { issue: issueId, stored: done, not_opened: failed, seconds: Math.round((Date.now() - started) / 1000), more: marks.length > BATCH });
  if (marks.length > BATCH) {
    const round = Number(payload.round ?? 0) + 1;
    await q(sql`SELECT platform.enqueue_job('watch.mark_embed', jsonb_build_object('issue_id', ${issueId}::uuid, 'round', ${round}::int), now(), ${`watch.mark_embed:${issueId}:${job.id}:${round}`})`);
  }
}
