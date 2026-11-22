import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Watch alerts of the signed-in account (MSM-PRD-02 Section 8; migration 0069). An alert belongs to one account and
 * one registry; row-level security shows an account its own alerts and only the published marks behind them.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });

export interface Reason { code: "same_text" | "similar_text" | "contained" | "sounds_alike" | "sounds_alike_cross" | "shared_first_word" | "shared_word"; script?: "en" | "ar"; score?: number; word?: string }
export interface AlertRow {
  id: string; band: "very_high" | "high" | "medium" | "low"; status: "new" | "reviewing" | "dismissed" | "relevant" | "actioned"; dismiss_reason: string | null; created_at: string;
  deadline: string | null; days_left: number | null; deadline_by_hand: boolean; record_id: string; registry_code: string;
  mark_text: I18nText | null; number: string | null; record_classes: number[];
  pub_text: I18nText | null; pub_no: string | null; pub_classes: number[]; applicant_name: string | null; applicant_country: string | null; agent_name: string | null;
  published_on: string; issue_no: string; score: number; goods: string | null;
  /** translation into the reader's language, beside the registry's own text (migration 0080) */
  t: Partial<Record<"applicant_name" | "agent_name" | "goods", string>> | null; class_kind: "same" | "different" | "related" | "outside"; class_overlap: number[]; reasons: Reason[];
}

export const ALERT_VIEWS = ["open", "new", "all"] as const;
export type AlertView = (typeof ALERT_VIEWS)[number];
export const DISMISS_REASONS = ["not_similar", "different_goods", "same_owner", "coexistence", "other"] as const;

export async function listAlerts(s: Session, view: AlertView, recordId?: string, sameClassOnly = false, lang = "en"): Promise<AlertRow[]> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT a.id, a.risk_band::text AS band, a.status::text, a.dismiss_reason, a.created_at, a.opposition_deadline::text AS deadline,
           -- days remaining count to the end of the last day in the registry's own time zone
           CASE WHEN a.opposition_deadline IS NOT NULL THEN a.opposition_deadline - (now() AT TIME ZONE COALESCE(p.rules #>> '{calendar,timezone}', 'UTC'))::date END AS days_left,
           a.deadline_entered_by IS NOT NULL AS deadline_by_hand, a.record_id, g.code AS registry_code,
           r.mark_text, COALESCE(r.registration_no, r.application_no) AS number, COALESCE(c.explanation -> 'record_classes', '[]'::jsonb) AS record_classes,
           m.mark_text AS pub_text, m.application_no AS pub_no, m.classes::int[] AS pub_classes, m.applicant_name, m.applicant_country, m.agent_name,
           m.publication_date::text AS published_on, i.issue_no, c.score::float8 AS score, c.explanation ->> 'class' AS class_kind, c.class_overlap::int[] AS class_overlap,
           COALESCE(c.explanation -> 'reasons', '[]'::jsonb) AS reasons, m.extraction ->> 'goods' AS goods, m.extraction -> 't' -> ${lang} AS t
      FROM watch.alert a
      JOIN watch.candidate c ON c.id = a.candidate_id
      JOIN watch.published_mark m ON m.id = c.published_mark_id AND m.registry_id = a.registry_id
      JOIN watch.publication_issue i ON i.id = m.issue_id
      JOIN core.record r ON r.id = a.record_id
      JOIN registry.registry g ON g.id = a.registry_id
      LEFT JOIN LATERAL registry.fn_current_profile(a.registry_id) p ON true
     WHERE (${view} = 'all' OR (${view} = 'new' AND a.status = 'new') OR (${view} = 'open' AND a.status IN ('new', 'reviewing')))
       AND (${recordId ?? null}::uuid IS NULL OR a.record_id = ${recordId ?? null}::uuid)
       AND (NOT ${sameClassOnly} OR c.explanation ->> 'class' = 'same')
     -- new first, then the same class before different classes (the class is information, ruling of 22 Nov 2026), then the stronger band
     ORDER BY (a.status = 'new') DESC, (c.explanation ->> 'class' = 'same') DESC, a.risk_band, a.opposition_deadline NULLS LAST, a.created_at DESC
     LIMIT 300`));
  return r as unknown as AlertRow[];
}

export async function countNewAlerts(s: Session): Promise<number> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT count(*)::int AS n FROM watch.alert WHERE status = 'new'`));
  return Number((r as unknown as Array<{ n: number }>)[0]?.n ?? 0);
}

export async function setAlert(s: Session, id: string, status: string, reason: string | null, deadline: string | null): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT watch.fn_alert_set(${id}::uuid, ${status}, ${reason}, ${deadline}::date)`));
}

/** Watch scope of one trademark (MSM-PRD-02 Section 7; migration 0070): the registries it is watched in, and those Meesam reads that could be added. */
export interface WatchRegistry { registry_id: string; code: string; name: I18nText; kind: "filed" | "watch_only" | null }
export interface RecordWatch { watched: boolean; alerts: number; open: number; watch_only_price: number | null; registries: WatchRegistry[] }
export async function recordWatch(s: Session, recordId: string): Promise<RecordWatch> {
  return withAccount(db(), ctx(s), async (tx) => {
    const head = (await tx.execute(sql`
      SELECT COALESCE(core.fn_record_watched(${recordId}::uuid), false) AS watched,
             (SELECT count(*)::int FROM watch.alert a WHERE a.record_id = ${recordId}::uuid) AS alerts,
             (SELECT count(*)::int FROM watch.alert a WHERE a.record_id = ${recordId}::uuid AND a.status IN ('new', 'reviewing')) AS open,
             (core.fn_price_list_rules() ->> 'watch_only')::float8 AS watch_only_price`)) as unknown as Array<{ watched: boolean; alerts: number; open: number; watch_only_price: number | null }>;
    const registries = (await tx.execute(sql`
      SELECT g.id AS registry_id, g.code, g.name, sc.kind::text AS kind
        FROM registry.registry g
        LEFT JOIN core.record_registry_scope sc ON sc.registry_id = g.id AND sc.record_id = ${recordId}::uuid
       WHERE sc.id IS NOT NULL OR EXISTS (SELECT 1 FROM watch.publication_source ps WHERE ps.registry_id = g.id AND ps.active)
       ORDER BY (sc.kind = 'filed') DESC NULLS LAST, (sc.id IS NOT NULL) DESC, g.launch_wave NULLS LAST, g.code`)) as unknown as WatchRegistry[];
    return { watched: Boolean(head[0]?.watched), alerts: Number(head[0]?.alerts ?? 0), open: Number(head[0]?.open ?? 0), watch_only_price: head[0]?.watch_only_price ?? null, registries };
  });
}
export async function setWatchRegistry(s: Session, recordId: string, registryId: string, on: boolean): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_record_watch_set(${recordId}::uuid, ${registryId}::uuid, ${on})`));
}

/** Publications of the registries this account watches that are still under review (PRD Section 8.5; migration 0073): counts only. */
export interface PendingIssue { registry_code: string; issue_no: string; published_on: string | null; marks: number; waiting: number }
export async function pendingIssues(s: Session): Promise<PendingIssue[]> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT registry_code, issue_no, published_on::text, marks, waiting FROM watch.fn_pending_issues()`));
  return r as unknown as PendingIssue[];
}

/** Low matches of one trademark (40 to 59): listed on its page, never an alert (ruling of 22 Nov 2026; migration 0079). */
export interface OtherMatch { registry_code: string; issue_no: string; published_on: string; pub_text: I18nText | null; pub_no: string | null; pub_classes: number[]; applicant_name: string | null; score: number; class_kind: string; reasons: Reason[] }
export async function otherMatches(s: Session, recordId: string): Promise<OtherMatch[]> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT registry_code, issue_no, published_on::text, pub_text, pub_no, pub_classes::int[] AS pub_classes, applicant_name, score::float8 AS score, class_kind, reasons
      FROM watch.fn_other_matches(${recordId}::uuid)`));
  return r as unknown as OtherMatch[];
}
