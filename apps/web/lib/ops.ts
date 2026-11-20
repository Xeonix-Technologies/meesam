import { sql } from "drizzle-orm";
import { createHash } from "node:crypto";
import { contentTypeOf, deleteObject, issueKey, putObject, shapeProblem, vaultConfig, withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Watch Operations Console (MSM-PRD-02 Section 9A), first part: the fetch stage. Read as meesam_staff; the
 * actions go through database functions that check the watch operations lead role and are audited.
 * No page here reads or edits a customer's trademark data, and none takes a file from a person (rule 7).
 */
const rows = <T>(r: unknown) => r as unknown as T[];
const read = <T>(q: ReturnType<typeof sql>) => withRole(db(), "meesam_staff", async (tx) => rows<T>(await tx.execute(q)));
const act = (s: Session, q: ReturnType<typeof sql>) => withRole(db(), "meesam_staff", async (tx) => {
  await tx.execute(sql`SELECT set_config('meesam.user_id', ${s.userId}, true)`);
  await tx.execute(q);
});

export type FetcherState = "off" | "noLocation" | "inside" | "manual" | "paused" | "failing" | "running";
export interface OpsSource {
  id: string; code: string; registry_name: I18nText; stream: string; format: string; cadence: string; active: boolean; paused: boolean; pause_note: string | null;
  fetch_spec: Record<string, unknown>; failures: number; last_polled_at: string | null; last_success_at: string | null; next_poll_at: string | null;
  issues: number; incident: boolean; profile_verified: boolean; window_days: number | null;
  manual_intake: boolean; manual_reason: string | null; manual_due_on: string | null; manual_due: boolean;
  frequency: string | null; weekday: number | null; local_time: string | null; timezone: string | null; expected_next: string | null; last_release: string | null; days_late: number | null;
}
export function fetcherState(s: OpsSource): FetcherState {
  if (!s.active) return "off";
  if (typeof s.fetch_spec.inside === "string") return "inside";
  if (s.manual_intake) return "manual";
  if (typeof s.fetch_spec.url !== "string") return "noLocation";
  if (s.paused) return "paused";
  if (s.incident || s.failures >= 3) return "failing";
  return "running";
}

export const listSources = () => read<OpsSource>(sql`
  SELECT s.id, g.code, g.name AS registry_name, s.stream::text, s.format::text, s.cadence, s.active, s.paused, s.pause_note, s.fetch_spec, s.failures,
         s.last_polled_at, s.last_success_at, s.next_poll_at,
         (SELECT count(*)::int FROM watch.publication_issue i WHERE i.source_id = s.id AND i.object_key IS NOT NULL) AS issues,
         EXISTS (SELECT 1 FROM watch.fetch_incident x WHERE x.source_id = s.id AND x.closed_at IS NULL) AS incident,
         COALESCE(p.verified, false) AS profile_verified, w.days AS window_days,
         s.manual_intake, s.manual_reason, watch.fn_manual_due_on(s.id)::text AS manual_due_on, COALESCE(watch.fn_manual_due_on(s.id) <= current_date, false) AS manual_due,
         c.frequency::text, c.weekday, c.local_time::text, COALESCE(c.timezone, w.timezone) AS timezone, c.expected_next::text,
         (SELECT max(i.published_on)::text FROM watch.publication_issue i WHERE i.source_id = s.id AND i.object_key IS NOT NULL) AS last_release,
         CASE WHEN c.expected_next < current_date THEN current_date - c.expected_next END AS days_late
    FROM watch.publication_source s
    JOIN registry.registry g ON g.id = s.registry_id
    LEFT JOIN LATERAL registry.fn_current_profile(s.registry_id) p ON true
    LEFT JOIN LATERAL watch.fn_source_window(s.id) w ON true
    LEFT JOIN watch.publication_schedule c ON c.source_id = s.id
   ORDER BY s.active DESC, g.launch_wave NULLS LAST, g.code, s.stream`);

export interface OpsIssue {
  id: string; code: string; stream: string; issue_no: string; title: string | null; published_on: string | null; fetched_at: string | null; container: string | null;
  size_bytes: string | null; checksum: string | null; fetch_status: string; stored: boolean; window_end: string | null; days_left: number | null; attempts: number; source_url: string | null;
  intake: string; added_by_name: string | null;
}
export const listIssues = () => read<OpsIssue>(sql`
  SELECT i.id, g.code, s.stream::text, i.issue_no, i.title, i.published_on::text, i.fetched_at, i.container, i.size_bytes::text,
         left(encode(i.sha256, 'hex'), 12) AS checksum, i.fetch_status::text, i.object_key IS NOT NULL AS stored,
         (i.published_on + w.days)::text AS window_end, CASE WHEN w.days IS NOT NULL THEN (i.published_on + w.days) - current_date END AS days_left,
         (SELECT count(*)::int FROM watch.fetch_run r WHERE r.issue_id = i.id) AS attempts, i.source_url,
         i.intake, (SELECT u.name FROM core.app_user u WHERE u.id = i.added_by) AS added_by_name
    FROM watch.publication_issue i
    JOIN watch.publication_source s ON s.id = i.source_id
    JOIN registry.registry g ON g.id = s.registry_id
    LEFT JOIN LATERAL watch.fn_source_window(s.id) w ON true
   ORDER BY COALESCE(i.published_on, i.created_at::date) DESC, i.created_at DESC LIMIT 200`);

export interface OpsIncident {
  id: string; code: string; stream: string; opened_at: string; closed_at: string | null; closed_by_name: string | null; close_note: string | null;
  detail: { step?: string; error?: string; failures?: number; issue_no?: string | null }; earliest_window_end: string | null; days_left: number | null;
}
export const listIncidents = () => read<OpsIncident>(sql`
  SELECT x.id, g.code, s.stream::text, x.opened_at, x.closed_at, u.name AS closed_by_name, x.close_note, x.detail,
         x.earliest_window_end::text, x.earliest_window_end - current_date AS days_left
    FROM watch.fetch_incident x
    JOIN watch.publication_source s ON s.id = x.source_id
    JOIN registry.registry g ON g.id = s.registry_id
    LEFT JOIN core.app_user u ON u.id = x.closed_by
   ORDER BY (x.closed_at IS NULL) DESC, x.opened_at DESC LIMIT 100`);

export interface OpsRun { id: string; code: string; stream: string; started_at: string; outcome: string | null; attempt: number; detail: { issue_no?: string | null; step?: string; error?: string; bytes?: number; duplicate?: boolean; listed?: number; manual?: boolean; by?: string; listing?: boolean; total?: number; links?: Array<{ text: string; before: string; url: string }> } }
export const listRuns = () => read<OpsRun>(sql`
  SELECT r.id, g.code, s.stream::text, r.started_at, r.outcome::text, r.attempt, r.detail
    FROM watch.fetch_run r
    JOIN watch.publication_source s ON s.id = r.source_id
    JOIN registry.registry g ON g.id = s.registry_id
   ORDER BY r.started_at DESC LIMIT 100`);

export const pauseSource = (s: Session, id: string, paused: boolean, note: string) => act(s, sql`SELECT watch.fn_source_pause(${id}::uuid, ${paused}, ${note || null})`);
export const pollSourceNow = (s: Session, id: string) => act(s, sql`SELECT watch.fn_source_poll_now(${id}::uuid)`);
export const closeIncident = (s: Session, id: string, note: string) => act(s, sql`SELECT watch.fn_incident_close(${id}::uuid, ${note || null})`);
export const confirmReuse = (s: Session, id: string, basis: string) => act(s, sql`SELECT watch.fn_source_confirm_reuse(${id}::uuid, ${basis})`);
export const setManual = (s: Session, id: string, on: boolean, reason: string) => act(s, sql`SELECT watch.fn_source_manual(${id}::uuid, ${on}, ${reason || null})`);

/** The largest publication a person may add by hand. Fetched files are streamed and may be larger; this one passes through the web service's memory. */
export const MAX_MANUAL_BYTES = 120 * 1024 * 1024;
export type ManualProblem = "notManual" | "shape" | "tooLarge" | "duplicate" | "date" | "required" | "bucket" | "generic";

/**
 * Temporary collection by hand (Founder ruling 19 Nov 2026): a file the watch operations lead downloaded from the
 * registry is checked exactly like a fetched one, stored once in the publications bucket and entered in the inbox.
 * The database refuses it unless the source is switched to "by hand" and the caller is the lead.
 */
export async function addManualIssue(s: Session, sourceId: string, issueNo: string, publishedOn: string, fileName: string, body: Buffer): Promise<{ ok: true } | { ok: false; problem: ManualProblem; detail?: string }> {
  const src = (await read<{ code: string; stream: string; container: string; min_bytes: number | null; manual_intake: boolean }>(sql`
    SELECT g.code, s.stream::text, COALESCE(s.fetch_spec ->> 'container', 'pdf') AS container, (s.fetch_spec ->> 'min_bytes')::int AS min_bytes, s.manual_intake
      FROM watch.publication_source s JOIN registry.registry g ON g.id = s.registry_id WHERE s.id = ${sourceId}::uuid AND s.active`))[0];
  if (!src || !src.manual_intake) return { ok: false, problem: "notManual" };
  if (!issueNo.trim() || !/^\d{4}-\d{2}-\d{2}$/.test(publishedOn)) return { ok: false, problem: "required" };
  if (body.length > MAX_MANUAL_BYTES) return { ok: false, problem: "tooLarge" };
  const problem = shapeProblem(body.subarray(0, 8), body.length, publishedOn, { container: src.container, min_bytes: src.min_bytes ?? undefined });
  if (problem) return { ok: false, problem: /future/.test(problem) ? "date" : "shape", detail: problem };
  let bucket;
  try { bucket = vaultConfig("PUBLICATIONS"); } catch { return { ok: false, problem: "bucket" }; }
  const sha = createHash("sha256").update(body).digest("hex");
  const key = issueKey(src.code, src.stream, issueNo.trim(), sha, src.container);
  await putObject(bucket, key, body, contentTypeOf(src.container));
  try {
    await act(s, sql`SELECT watch.fn_manual_add(${sourceId}::uuid, ${issueNo.trim()}, ${publishedOn}::date, ${key}, decode(${sha}, 'hex'), ${body.length}::bigint, ${src.container}, ${fileName.slice(0, 200)})`);
    return { ok: true };
  } catch (e) {
    // the record was refused: the file must not stay behind without one
    await deleteObject(bucket, key).catch(() => undefined);
    const err = e as Error & { cause?: { code?: string; message?: string } };
    const code = err.cause?.code;
    if (code === "23505") return { ok: false, problem: "duplicate" };
    if (code === "22008") return { ok: false, problem: "date" };
    if (code === "42501") return { ok: false, problem: "notManual" };
    console.error(JSON.stringify({ level: "error", at: "ops.manual", message: err.cause?.message ?? err.message }));
    return { ok: false, problem: "generic" };
  }
}
