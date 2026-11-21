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

export interface Reason { code: "same_text" | "similar_text" | "contained" | "sounds_alike" | "sounds_alike_cross"; script?: "en" | "ar"; score?: number }
export interface AlertRow {
  id: string; band: "high" | "medium" | "low"; status: "new" | "reviewing" | "dismissed" | "relevant" | "actioned"; dismiss_reason: string | null; created_at: string;
  deadline: string | null; days_left: number | null; deadline_by_hand: boolean; record_id: string; registry_code: string;
  mark_text: I18nText | null; number: string | null; record_classes: number[];
  pub_text: I18nText | null; pub_no: string | null; pub_classes: number[]; applicant_name: string | null; applicant_country: string | null; agent_name: string | null;
  published_on: string; issue_no: string; score: number; class_kind: "same" | "related" | "outside"; class_overlap: number[]; reasons: Reason[];
}

export const ALERT_VIEWS = ["open", "new", "all"] as const;
export type AlertView = (typeof ALERT_VIEWS)[number];
export const DISMISS_REASONS = ["not_similar", "different_goods", "same_owner", "coexistence", "other"] as const;

export async function listAlerts(s: Session, view: AlertView, recordId?: string): Promise<AlertRow[]> {
  const r = await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT a.id, a.risk_band::text AS band, a.status::text, a.dismiss_reason, a.created_at, a.opposition_deadline::text AS deadline,
           -- days remaining count to the end of the last day in the registry's own time zone
           CASE WHEN a.opposition_deadline IS NOT NULL THEN a.opposition_deadline - (now() AT TIME ZONE COALESCE(p.rules #>> '{calendar,timezone}', 'UTC'))::date END AS days_left,
           a.deadline_entered_by IS NOT NULL AS deadline_by_hand, a.record_id, g.code AS registry_code,
           r.mark_text, COALESCE(r.registration_no, r.application_no) AS number, COALESCE(c.explanation -> 'record_classes', '[]'::jsonb) AS record_classes,
           m.mark_text AS pub_text, m.application_no AS pub_no, m.classes::int[] AS pub_classes, m.applicant_name, m.applicant_country, m.agent_name,
           m.publication_date::text AS published_on, i.issue_no, c.score::float8 AS score, c.explanation ->> 'class' AS class_kind, c.class_overlap::int[] AS class_overlap,
           COALESCE(c.explanation -> 'reasons', '[]'::jsonb) AS reasons
      FROM watch.alert a
      JOIN watch.candidate c ON c.id = a.candidate_id
      JOIN watch.published_mark m ON m.id = c.published_mark_id AND m.registry_id = a.registry_id
      JOIN watch.publication_issue i ON i.id = m.issue_id
      JOIN core.record r ON r.id = a.record_id
      JOIN registry.registry g ON g.id = a.registry_id
      LEFT JOIN LATERAL registry.fn_current_profile(a.registry_id) p ON true
     WHERE (${view} = 'all' OR (${view} = 'new' AND a.status = 'new') OR (${view} = 'open' AND a.status IN ('new', 'reviewing')))
       AND (${recordId ?? null}::uuid IS NULL OR a.record_id = ${recordId ?? null}::uuid)
     ORDER BY (a.status = 'new') DESC, a.opposition_deadline NULLS LAST, (a.risk_band = 'high') DESC, a.created_at DESC
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
