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

/** Re-use register (Founder ruling R8, 21 Nov 2026; migration 0060): one row per registry that has a publication source. */
export interface OpsReuse {
  registry_id: string; code: string; registry_name: I18nText; terms: string | null; terms_url: string | null; read_on: string | null;
  may_store: boolean | null; may_show: boolean | null; may_derive: boolean | null; may_train: boolean | null; may_contact: boolean | null;
  note: string | null; updated_by_name: string | null; updated_at: string | null; sources_on: number;
}
export const listReuse = () => read<OpsReuse>(sql`
  SELECT g.id AS registry_id, g.code, g.name AS registry_name, r.terms, r.terms_url, r.read_on::text,
         r.may_store, r.may_show, r.may_derive, r.may_train, r.may_contact, r.note,
         (SELECT u.name FROM core.app_user u WHERE u.id = r.updated_by) AS updated_by_name, r.updated_at,
         (SELECT count(*)::int FROM watch.publication_source s WHERE s.registry_id = g.id AND s.active) AS sources_on
    FROM registry.registry g
    LEFT JOIN watch.reuse_register r ON r.registry_id = g.id
   WHERE EXISTS (SELECT 1 FROM watch.publication_source s WHERE s.registry_id = g.id)
   ORDER BY (r.registry_id IS NULL), g.launch_wave NULLS LAST, g.code`);
export const setReuse = (s: Session, registryId: string, v: { terms: string; url: string; readOn: string | null; store: boolean | null; show: boolean | null; derive: boolean | null; train: boolean | null; contact: boolean | null; note: string }) =>
  act(s, sql`SELECT watch.fn_reuse_set(${registryId}::uuid, ${v.terms}, ${v.url}, ${v.readOn}::date, ${v.store}::boolean, ${v.show}::boolean, ${v.derive}::boolean, ${v.train}::boolean, ${v.contact}::boolean, ${v.note})`);

/** Data quality (Founder ruling R8; Data Management and Use 5.6): per source, what was expected, fetched, read and verified. */
export interface OpsQuality {
  id: string; code: string; stream: string; active: boolean; manual_intake: boolean; days_late: number | null; last_release: string | null;
  stored: number; to_read: number; failed_30d: number; runs_30d: number; open_incident: boolean; marks: number; to_verify: number;
}
export const listQuality = () => read<OpsQuality>(sql`
  SELECT s.id, g.code, s.stream::text, s.active, s.manual_intake,
         CASE WHEN c.expected_next < current_date THEN current_date - c.expected_next END AS days_late,
         (SELECT max(i.published_on)::text FROM watch.publication_issue i WHERE i.source_id = s.id AND i.object_key IS NOT NULL) AS last_release,
         (SELECT count(*)::int FROM watch.publication_issue i WHERE i.source_id = s.id AND i.object_key IS NOT NULL) AS stored,
         (SELECT count(*)::int FROM watch.publication_issue i WHERE i.source_id = s.id AND i.object_key IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM watch.published_mark m WHERE m.issue_id = i.id)) AS to_read,
         (SELECT count(*)::int FROM watch.fetch_run r WHERE r.source_id = s.id AND r.outcome = 'failed' AND r.started_at > now() - interval '30 days') AS failed_30d,
         (SELECT count(*)::int FROM watch.fetch_run r WHERE r.source_id = s.id AND r.started_at > now() - interval '30 days') AS runs_30d,
         EXISTS (SELECT 1 FROM watch.fetch_incident x WHERE x.source_id = s.id AND x.closed_at IS NULL) AS open_incident,
         (SELECT count(*)::int FROM watch.published_mark m JOIN watch.publication_issue i ON i.id = m.issue_id WHERE i.source_id = s.id) AS marks,
         (SELECT count(*)::int FROM watch.published_mark m JOIN watch.publication_issue i ON i.id = m.issue_id WHERE i.source_id = s.id AND m.verify_state = 'ai_extracted') AS to_verify
    FROM watch.publication_source s
    JOIN registry.registry g ON g.id = s.registry_id
    LEFT JOIN watch.publication_schedule c ON c.source_id = s.id
   WHERE s.active AND NOT (s.fetch_spec ? 'inside')
   ORDER BY g.launch_wave NULLS LAST, g.code, s.stream`);

/** Reading tests (plan item A1, first step; migration 0064): a few pages of a stored issue through the AI reader. */
export const READ_MODELS = ["claude-sonnet-5-5", "claude-haiku-5-5"] as const;
export interface ReadMark {
  page?: number; printed_page?: string | number | null; pages?: number; continues?: boolean; application_no?: string | null; registration_no?: string | null; filing_date?: string | null; mark_text_ar?: string | null; mark_text_en?: string | null;
  mark_type?: string | null; has_image?: boolean; image_description?: string | null; classes?: number[]; goods?: string | null;
  applicant_name?: string | null; applicant_country?: string | null; agent_name?: string | null; confidence?: number;
}
export interface OpsReadTest {
  id: string; code: string; stream: string; issue_no: string; first_page: number; pages: number; model: string; status: string; auto_start: boolean; created_at: string;
  file_name: string | null; page_count: number | null; input_tokens: number | null; output_tokens: number | null; seconds: number | null;
  result: { page_kind?: string; language?: string; marks?: ReadMark[]; notes?: string | null } | null; error: string | null; requested_by_name: string | null;
}
export const listReadTests = () => read<OpsReadTest>(sql`
  SELECT t.id, g.code, s.stream::text, i.issue_no, t.first_page, t.pages, t.model, t.auto_start,
         -- a test with no outcome after an hour was interrupted (the worker restarted in the middle)
         CASE WHEN t.status IN ('queued', 'running') AND t.created_at < now() - interval '1 hour' THEN 'failed' ELSE t.status END AS status,
         t.created_at, t.file_name, t.page_count, t.input_tokens, t.output_tokens,
         extract(epoch FROM t.finished_at - t.started_at)::int AS seconds, t.result,
         CASE WHEN t.status IN ('queued', 'running') AND t.created_at < now() - interval '1 hour' THEN 'Interrupted before it finished' ELSE t.error END AS error,
         (SELECT u.name FROM core.app_user u WHERE u.id = t.requested_by) AS requested_by_name
    FROM watch.read_test t
    JOIN watch.publication_issue i ON i.id = t.issue_id
    JOIN watch.publication_source s ON s.id = i.source_id
    JOIN registry.registry g ON g.id = s.registry_id
   ORDER BY t.created_at DESC LIMIT 20`);
export const requestReadTest = (s: Session, issueId: string, firstPage: number, pages: number, model: string) =>
  act(s, sql`SELECT watch.fn_read_test_request(${issueId}::uuid, ${firstPage}::int, ${pages}::int, ${model})`);

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
