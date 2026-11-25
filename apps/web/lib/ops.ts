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
  intake: string; added_by_name: string | null; readable: boolean; has_layout: boolean; by_codes: boolean;
}
export const listIssues = () => read<OpsIssue>(sql`
  SELECT i.id, g.code, s.stream::text, i.issue_no, i.title, i.published_on::text, i.fetched_at, i.container, i.size_bytes::text,
         left(encode(i.sha256, 'hex'), 12) AS checksum, i.fetch_status::text, i.object_key IS NOT NULL AS stored,
         (i.published_on + w.days)::text AS window_end, CASE WHEN w.days IS NOT NULL THEN (i.published_on + w.days) - current_date END AS days_left,
         (SELECT count(*)::int FROM watch.fetch_run r WHERE r.issue_id = i.id) AS attempts, i.source_url,
         i.intake, (SELECT u.name FROM core.app_user u WHERE u.id = i.added_by) AS added_by_name,
         -- stored and dated: it can be read (in full where the registry's layout is entered; otherwise a few pages at a time)
         (i.object_key IS NOT NULL AND i.published_on IS NOT NULL) AS readable,
         COALESCE(s.fetch_spec -> 'read' ?| ARRAY['entry_start', 'entry_marker'], false) OR COALESCE(s.fetch_spec -> 'read' ->> 'method', '') IN ('codes', 'labels') AS has_layout,
         -- read from the file's own text by its printed codes, without the AI reader (migration 0081)
         COALESCE(s.fetch_spec -> 'read' ->> 'method', '') IN ('codes', 'labels') AS by_codes
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
/** Languages a reading test may translate into (codes are data; names come from the browser's own language names). */
export const READ_LANGS = ["en", "fr", "tr", "zh", "es", "de", "ru", "hi", "ur", "fa"] as const;
export interface ReadMark {
  page?: number; printed_page?: string | number | null; pages?: number; continues?: boolean; application_no?: string | null; registration_no?: string | null; filing_date?: string | null; mark_text_ar?: string | null; mark_text_en?: string | null;
  mark_type?: string | null; has_image?: boolean; image_description?: string | null; classes?: number[]; goods?: string | null;
  applicant_name?: string | null; applicant_country?: string | null; agent_name?: string | null; agent_city?: string | null; confidence?: number;
  applicant_name_t?: string | null; agent_name_t?: string | null; goods_t?: string | null; mark_meaning_t?: string | null;
}
export interface OpsReadTest {
  id: string; code: string; stream: string; issue_no: string; first_page: number; pages: number; model: string; status: string; auto_start: boolean; translate_to: string | null; created_at: string;
  file_name: string | null; page_count: number | null; input_tokens: number | null; output_tokens: number | null; seconds: number | null;
  result: { page_kind?: string; language?: string; marks?: ReadMark[]; notes?: string | null; start?: string } | null; error: string | null; requested_by_name: string | null;
}
export const listReadTests = () => read<OpsReadTest>(sql`
  SELECT t.id, g.code, s.stream::text, i.issue_no, t.first_page, t.pages, t.model, t.auto_start, t.translate_to,
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
export const requestReadTest = (s: Session, issueId: string, firstPage: number, pages: number, model: string, translateTo: string | null) =>
  act(s, sql`SELECT watch.fn_read_test_request(${issueId}::uuid, ${firstPage}::int, ${pages}::int, ${model}, ${translateTo})`);

/** Reading a whole issue (plan item A1; migration 0067): every mark is stored waiting for verification; the outcome compares it with the registry's index. */
export interface ReadOutcome {
  index_read?: boolean; index_rows?: number; marks?: number; without_number?: number; entry_pages?: number | null;
  missing?: Array<{ no: string; class: number | null; page: string | null }>; not_in_index?: Array<{ no: string; page: string | null }>;
  class_differs?: Array<{ no: string; index: number; read: number[] }>; pages_not_read?: Array<{ from: number; to: number; kind: string; why: string | null }>;
}
export interface OpsReadRun {
  id: string; code: string; stream: string; issue_no: string; model: string; status: string; created_at: string; file_name: string | null;
  page_count: number | null; first_page: number | null; entries_found: number | null; from_page: number | null; to_page: number | null; parts_total: number; parts_done: number; parts_failed: number; marks: number;
  input_tokens: string; output_tokens: string; seconds: number | null; outcome: ReadOutcome | null; error: string | null; requested_by_name: string | null;
}
const RUN_COLUMNS = sql`
  u.id, g.code, s.stream::text, i.issue_no, u.model,
  -- a run that has not moved for half an hour is not moving (the worker lost it); the lead can stop it and start again
  CASE WHEN u.status IN ('queued', 'reading') AND u.updated_at < now() - interval '30 minutes' THEN 'stalled' ELSE u.status END AS status,
  u.created_at, u.file_name, u.page_count, u.first_page, u.entries_found, u.from_page, u.to_page, u.parts_total,
  (SELECT count(*)::int FROM watch.read_part p WHERE p.run_id = u.id AND p.status = 'done') AS parts_done,
  (SELECT count(*)::int FROM watch.read_part p WHERE p.run_id = u.id AND p.status = 'failed') AS parts_failed,
  (SELECT count(*)::int FROM watch.published_mark m WHERE m.issue_id = u.issue_id AND m.extraction ->> 'run_id' = u.id::text) AS marks,
  u.input_tokens::text, u.output_tokens::text, extract(epoch FROM COALESCE(u.finished_at, now()) - u.started_at)::int AS seconds, u.outcome, u.error,
  (SELECT x.name FROM core.app_user x WHERE x.id = u.requested_by) AS requested_by_name`;
const RUN_FROM = sql`watch.read_run u JOIN watch.publication_issue i ON i.id = u.issue_id JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id`;
export const listReadRuns = () => read<OpsReadRun>(sql`SELECT ${RUN_COLUMNS} FROM ${RUN_FROM} ORDER BY u.created_at DESC LIMIT 12`);
export const getReadRun = async (id: string) => (await read<OpsReadRun>(sql`SELECT ${RUN_COLUMNS} FROM ${RUN_FROM} WHERE u.id = ${id}::uuid`))[0] ?? null;
export interface OpsRunMark extends ReadMark { verify_state: string }
/** The marks a run stored, in the order of the issue's pages, each as the reader gave it. */
export const listRunMarks = (id: string) => read<OpsRunMark>(sql`
  SELECT (m.extraction ->> 'page')::int AS page, m.extraction ->> 'printed_page' AS printed_page, (m.extraction ->> 'pages')::int AS pages,
         m.application_no, m.extraction ->> 'registration_no' AS registration_no, m.extraction ->> 'filing_date' AS filing_date,
         m.mark_text ->> 'ar' AS mark_text_ar, m.mark_text ->> 'en' AS mark_text_en, m.extraction ->> 'mark_type' AS mark_type,
         COALESCE((m.extraction ->> 'has_image')::boolean, false) AS has_image, m.extraction ->> 'image_description' AS image_description,
         m.classes::int[] AS classes, m.extraction ->> 'goods' AS goods, m.applicant_name, m.applicant_country, m.agent_name, m.extraction ->> 'agent_city' AS agent_city,
         (m.extraction ->> 'confidence')::float8 AS confidence, m.verify_state::text
    FROM watch.read_run u JOIN watch.published_mark m ON m.issue_id = u.issue_id AND m.extraction ->> 'run_id' = u.id::text
   WHERE u.id = ${id}::uuid
   ORDER BY (m.extraction ->> 'page')::int NULLS LAST, m.application_no LIMIT 1000`);
export const requestReadRun = (s: Session, issueId: string, model: string, fromPage: number | null = null, toPage: number | null = null) =>
  act(s, sql`SELECT watch.fn_read_run_request(${issueId}::uuid, ${model}, NULL, ${fromPage}::int, ${toPage}::int)`);
export const stopReadRun = (s: Session, runId: string) => act(s, sql`SELECT watch.fn_read_run_stop(${runId}::uuid)`);

/** The reviewer's queue (plan item A2; migration 0068): marks read by the AI reader, waiting for a person to confirm or correct them. */
export interface OpsVerifyIssue {
  issue_id: string; code: string; stream: string; issue_no: string; published_on: string | null; total: number; waiting: number; corrected: number;
  /** read by rules, complete and in the office's own list: accepted without a person (migration 0082) */
  accepted: number;
  /** what comparing the verified marks produced (migration 0070): counts only */
  compared: number; matches: number; alerts: number; held: number; own: number; waiting_jobs: number;
  /** matches too weak to alert, listed on the trademark's page only; watched trademarks in this registry, all accounts together; whether "show" is confirmed (migration 0081) */
  low: number; watched: number; may_show: boolean;
}
export const listVerifyIssues = () => read<OpsVerifyIssue>(sql`
  SELECT q.*, c.compared, c.matches, c.alerts, c.held, c.own, c.waiting_jobs, c.low, c.watched, COALESCE(c.may_show, false) AS may_show
    FROM (
      SELECT i.id AS issue_id, g.code, s.stream::text, i.issue_no, i.published_on::text, count(*)::int AS total,
             (count(*) FILTER (WHERE m.verify_state = 'ai_extracted'))::int AS waiting,
             (count(*) FILTER (WHERE m.verify_state = 'waived' AND m.extraction ->> 'accepted' = 'rules'))::int AS accepted,
             (count(*) FILTER (WHERE m.verify_state = 'human_verified' AND jsonb_array_length(COALESCE(m.extraction -> 'corrected', '[]'::jsonb)) > 0))::int AS corrected
        FROM watch.published_mark m
        JOIN watch.publication_issue i ON i.id = m.issue_id
        JOIN watch.publication_source s ON s.id = i.source_id
        JOIN registry.registry g ON g.id = s.registry_id
       GROUP BY i.id, g.code, s.stream, i.issue_no, i.published_on
    ) q, LATERAL watch.fn_issue_compare_summary(q.issue_id) c
   ORDER BY q.waiting = 0, q.published_on DESC NULLS LAST LIMIT 100`);
/** The waiting marks of an issue, in the order of its pages. */
export const listWaitingMarks = (issueId: string) => read<{ id: string }>(sql`
  SELECT m.id FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.verify_state = 'ai_extracted'
   ORDER BY COALESCE(m.extraction ->> 'part', ''), (CASE WHEN m.extraction ->> 'page' ~ '^[0-9]+$' THEN (m.extraction ->> 'page')::int END) NULLS LAST, m.application_no, m.id LIMIT 20000`);
/** A waiting mark found by its number as printed (spaces, slashes and dashes do not matter). */
export const findWaitingMark = async (issueId: string, no: string) => (await read<{ id: string }>(sql`
  SELECT m.id FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.verify_state = 'ai_extracted' AND core.fn_number_key(m.application_no) = core.fn_number_key(${no}) LIMIT 1`))[0]?.id ?? null;
/** Whether a number is in the issue at all, for telling "already verified" from "not in this issue". */
export const markNumberInIssue = async (issueId: string, no: string) => (await read<{ n: number }>(sql`
  SELECT count(*)::int AS n FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND core.fn_number_key(m.application_no) = core.fn_number_key(${no})`))[0]?.n ?? 0;
export interface OpsVerifyMark {
  id: string; code: string; stream: string; issue_no: string; verify_state: string; page: number | null; printed_page: string | null; application_no: string | null; filing_date: string | null;
  mark_text_ar: string | null; mark_text_en: string | null; mark_type: string | null; has_image: boolean; image_description: string | null; classes: number[]; goods: string | null;
  applicant_name: string | null; applicant_country: string | null; applicant_address: string | null; agent_name: string | null; agent_city: string | null; confidence: number | null;
  has_page: boolean; page_from: number | null; page_to: number | null; total: number; waiting: number;
  /** how it was read ("codes" or "labels": from the file's own text by rules), and what else the entry states */
  read_by: string | null; file: string | null; international_no: string | null; figure_codes: string | null; read_notes: string | null;
  /** the translation into the page's language, when one was made (migration 0080); `pending` while it is being made */
  t: Partial<Record<"applicant_name" | "applicant_address" | "agent_name" | "agent_city" | "goods" | "image_description" | "source_language", string>> | null; t_pending: boolean;
}
export const getVerifyMark = async (issueId: string, markId: string, lang: string) => (await read<OpsVerifyMark>(sql`
  SELECT m.id, g.code, s.stream::text, i.issue_no, m.verify_state::text, CASE WHEN m.extraction ->> 'page' ~ '^[0-9]+$' THEN (m.extraction ->> 'page')::int END AS page, m.extraction ->> 'printed_page' AS printed_page,
         m.application_no, m.extraction ->> 'filing_date' AS filing_date, m.mark_text ->> 'ar' AS mark_text_ar, m.mark_text ->> 'en' AS mark_text_en, m.extraction ->> 'mark_type' AS mark_type,
         COALESCE(m.extraction ->> 'has_image' = 'true', false) AS has_image, m.extraction ->> 'image_description' AS image_description, m.classes::int[] AS classes, m.extraction ->> 'goods' AS goods,
         m.applicant_name, m.applicant_country, m.extraction ->> 'applicant_address' AS applicant_address, m.agent_name, m.extraction ->> 'agent_city' AS agent_city,
         CASE WHEN jsonb_typeof(m.extraction -> 'confidence') = 'number' THEN (m.extraction ->> 'confidence')::float8 END AS confidence,
         -- a translation made under the earlier rules (names written as they sound) is not shown; it is made again
         CASE WHEN m.extraction -> 't' -> ${lang} ->> 'rules' = '2' THEN m.extraction -> 't' -> ${lang} END AS t,
         EXISTS (SELECT 1 FROM platform.job j WHERE j.kind = 'watch.translate' AND j.status IN ('queued', 'running') AND j.payload ->> 'mark_id' = m.id::text AND j.payload ->> 'lang' = ${lang}) AS t_pending,
         m.extraction ->> 'read_by' AS read_by, m.extraction ->> 'file' AS file, m.extraction ->> 'international_no' AS international_no, m.extraction ->> 'figure_codes' AS figure_codes, m.extraction ->> 'notes' AS read_notes,
         m.extraction ? 'page_key' AS has_page, (m.extraction ->> 'page_from')::int AS page_from, (m.extraction ->> 'page_to')::int AS page_to,
         (SELECT count(*)::int FROM watch.published_mark x WHERE x.issue_id = m.issue_id) AS total,
         (SELECT count(*)::int FROM watch.published_mark x WHERE x.issue_id = m.issue_id AND x.verify_state = 'ai_extracted') AS waiting
    FROM watch.published_mark m JOIN watch.publication_issue i ON i.id = m.issue_id JOIN watch.publication_source s ON s.id = i.source_id JOIN registry.registry g ON g.id = s.registry_id
   WHERE m.issue_id = ${issueId}::uuid AND m.id = ${markId}::uuid`))[0] ?? null;
/** Where the mark's own page(s), cut out of the issue, are kept in the publications bucket. */
export const getMarkPageKey = async (issueId: string, markId: string) => (await read<{ page_key: string | null }>(sql`
  SELECT m.extraction ->> 'page_key' AS page_key FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.id = ${markId}::uuid`))[0]?.page_key ?? null;
export const verifyMark = (s: Session, issueId: string, markId: string, fix: Record<string, unknown>) => act(s, sql`SELECT watch.fn_mark_verify(${issueId}::uuid, ${markId}::uuid, ${JSON.stringify(fix)}::jsonb)`);
/** What arrives a little after a mark is opened: its translation and its page(s). Asked again by the page until both are there. */
export interface MarkAux { t: OpsVerifyMark["t"]; t_pending: boolean; has_page: boolean; page_pending: boolean }
export const getMarkAux = async (issueId: string, markId: string, lang: string) => (await read<MarkAux>(sql`
  SELECT CASE WHEN m.extraction -> 't' -> ${lang} ->> 'rules' = '2' THEN m.extraction -> 't' -> ${lang} END AS t,
         EXISTS (SELECT 1 FROM platform.job j WHERE j.kind = 'watch.translate' AND j.status IN ('queued', 'running') AND j.payload ->> 'mark_id' = m.id::text AND j.payload ->> 'lang' = ${lang}) AS t_pending,
         m.extraction ? 'page_key' AS has_page,
         EXISTS (SELECT 1 FROM platform.job j WHERE j.kind = 'watch.mark_pages' AND j.status IN ('queued', 'running') AND j.payload ->> 'issue_id' = m.issue_id::text) AS page_pending
    FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.id = ${markId}::uuid`))[0] ?? null;
export const requestMarkPages = (s: Session, issueId: string, markId: string) => act(s, sql`SELECT watch.fn_mark_pages_request(${issueId}::uuid, ${markId}::uuid)`);
export const compareIssueAgain = (s: Session, issueId: string) => act(s, sql`SELECT watch.fn_issue_compare_again(${issueId}::uuid)`);
export const requestTranslation = (s: Session, issueId: string, markId: string, lang: string) => act(s, sql`SELECT watch.fn_translation_request(${issueId}::uuid, ${markId}::uuid, ${lang})`);
export const rejectMark = (s: Session, issueId: string, markId: string, reason: string) => act(s, sql`SELECT watch.fn_mark_reject(${issueId}::uuid, ${markId}::uuid, ${reason})`);

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
  // Where the registry publishes an archive (the UAE bulletin is a .rar holding several PDFs), the lead may add the
  // bulletin's PDF taken out of that archive: it is checked as a PDF and recorded as one. The minimum size of the
  // archive does not apply to one part of it; the ordinary minimum for an issue does.
  // RULING NEEDED: confirm that the temporary collection by hand may take the PDF from inside the registry's archive.
  const isPdf = body.length >= 4 && body[0] === 0x25 && body[1] === 0x50 && body[2] === 0x44 && body[3] === 0x46;
  if (src.container !== "pdf" && isPdf) src.container = "pdf", src.min_bytes = null;
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

// ---- Pictures: look-alikes (a staff view for judging the picture fingerprints; nothing here raises an alert) ----

export interface OpsPictureIssue { issue_id: string; code: string; stream: string; issue_no: string; published_on: string | null; total: number; pictures: number; siglip: number; dino: number }
/** The issues that hold marks, with how many have a picture and each model's fingerprint. */
export const listPictureIssues = () => read<OpsPictureIssue>(sql`
  SELECT i.id AS issue_id, g.code, s.stream::text, i.issue_no, i.published_on::text, count(*)::int AS total,
         (count(*) FILTER (WHERE m.extraction ? 'image_key'))::int AS pictures,
         (count(*) FILTER (WHERE m.siglip_embedding IS NOT NULL))::int AS siglip,
         (count(*) FILTER (WHERE m.dino_embedding IS NOT NULL))::int AS dino
    FROM watch.published_mark m
    JOIN watch.publication_issue i ON i.id = m.issue_id
    JOIN watch.publication_source s ON s.id = i.source_id
    JOIN registry.registry g ON g.id = s.registry_id
   GROUP BY i.id, g.code, s.stream, i.issue_no, i.published_on
  HAVING count(*) FILTER (WHERE m.extraction ? 'image_key') > 0
   ORDER BY i.published_on DESC NULLS LAST, i.issue_no DESC`);

export interface OpsPictureMark {
  id: string; application_no: string | null; mark_ar: string | null; mark_en: string | null; classes: number[]; applicant_name: string | null;
  part: string | null; has_siglip: boolean; has_dino: boolean; same_picture: number;
}
const PICTURE_COLS = sql`m.id, m.application_no, m.mark_text ->> 'ar' AS mark_ar, m.mark_text ->> 'en' AS mark_en, m.classes, m.applicant_name, m.extraction ->> 'part' AS part,
  m.siglip_embedding IS NOT NULL AS has_siglip, m.dino_embedding IS NOT NULL AS has_dino,
  (SELECT count(*)::int FROM watch.published_mark o WHERE o.issue_id = m.issue_id AND o.id <> m.id AND o.extraction ->> 'image_phash' = m.extraction ->> 'image_phash') AS same_picture`;
/** One mark of the issue that has a picture: the one asked for by id or by number, another one at random, or the first. */
export const getPictureMark = async (issueId: string, by: { id?: string; no?: string; random?: boolean }) => (await read<OpsPictureMark>(
  by.id ? sql`SELECT ${PICTURE_COLS} FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.id = ${by.id}::uuid AND m.extraction ? 'image_key'`
  : by.no ? sql`SELECT ${PICTURE_COLS} FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.extraction ? 'image_key'
       AND core.fn_number_key(m.application_no) = core.fn_number_key(${by.no}) ORDER BY m.id LIMIT 1`
  : by.random ? sql`SELECT ${PICTURE_COLS} FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.extraction ? 'image_key' AND m.siglip_embedding IS NOT NULL ORDER BY random() LIMIT 1`
  : sql`SELECT ${PICTURE_COLS} FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.extraction ? 'image_key'
       ORDER BY (m.siglip_embedding IS NULL), COALESCE(m.extraction ->> 'part', ''), (CASE WHEN m.extraction ->> 'page' ~ '^[0-9]+$' THEN (m.extraction ->> 'page')::int END) NULLS LAST, m.id LIMIT 1`))[0] ?? null;

export interface OpsLookalike {
  id: string; application_no: string | null; mark_ar: string | null; mark_en: string | null; classes: number[]; applicant_name: string | null;
  siglip: number | null; dino: number | null; rank_siglip: number | null; rank_dino: number | null;
}
/**
 * The marks of the same issue whose pictures stand nearest to one mark's picture: the first `n` by each model, each
 * with both models' closeness (0 to 100; 100 is the same direction, as the models see the two pictures).
 * A notice that carries the very same picture (the same mark in another class) is left out and counted apart.
 * The query is the database function watch.fn_mark_lookalikes (migration 0092), so it is tested with real vectors.
 */
export const listLookalikes = (issueId: string, markId: string, n = 10) => read<OpsLookalike>(sql`
  SELECT id, application_no, mark_ar, mark_en, classes, applicant_name, siglip, dino, rank_siglip, rank_dino FROM watch.fn_mark_lookalikes(${issueId}::uuid, ${markId}::uuid, ${n}::int)`);
/** Where a mark's picture, cut out of the issue, is kept in the publications bucket. */
export const getMarkPictureKey = async (issueId: string, markId: string) => (await read<{ k: string | null }>(sql`
  SELECT m.extraction ->> 'image_key' AS k FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.id = ${markId}::uuid`))[0]?.k ?? null;
/** For each model, how many marks of the issue have their nearest other picture in each step of ten (migration 0093). Asked for on demand: it compares every mark with every other. */
export const getPictureSpread = (issueId: string) => read<{ model: string; step: number; marks: number }>(sql`
  SELECT model, step, marks FROM watch.fn_issue_picture_spread(${issueId}::uuid) ORDER BY model, step DESC`);
/** A picture's two fingerprints as the picture service gave them, with the name of the engine that made each. */
export interface PictureProbe { siglip: string | null; siglipEngine: string | null; dino: string | null; dinoEngine: string | null }
/** One picture given by staff against every picture of an issue: the first `n` by each model (migration 0094). */
export const probeIssuePictures = (issueId: string, p: PictureProbe, n = 10) => read<OpsLookalike>(sql`
  SELECT id, application_no, mark_ar, mark_en, classes, applicant_name, siglip, dino, rank_siglip, rank_dino
    FROM watch.fn_issue_picture_probe(${issueId}::uuid, ${p.siglip}, ${p.siglipEngine}, ${p.dino}, ${p.dinoEngine}, ${n}::int)`);
/** For the same picture: how many pictures of the issue stand in each step of ten of closeness to it. */
export const probeIssueSpread = (issueId: string, p: PictureProbe) => read<{ model: string; step: number; marks: number }>(sql`
  SELECT model, step, marks FROM watch.fn_issue_picture_probe_spread(${issueId}::uuid, ${p.siglip}, ${p.siglipEngine}, ${p.dino}, ${p.dinoEngine})`);
/** The marks of an issue named by id, for showing a result that travelled in the page's address. */
export const listPictureMarksByIds = (issueId: string, ids: string[]) => read<{ id: string; application_no: string | null; mark_ar: string | null; mark_en: string | null; classes: number[]; applicant_name: string | null }>(sql`
  SELECT m.id, m.application_no, m.mark_text ->> 'ar' AS mark_ar, m.mark_text ->> 'en' AS mark_en, m.classes, m.applicant_name
    FROM watch.published_mark m WHERE m.issue_id = ${issueId}::uuid AND m.extraction ? 'image_key' AND m.id = ANY(string_to_array(${ids.join(",")}, ',')::uuid[])`);
