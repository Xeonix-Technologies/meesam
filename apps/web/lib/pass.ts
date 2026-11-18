import { sql } from "drizzle-orm";
import { withAccount, withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Owner pass (System Description 4.4 link 2): an agency that entered a record for a client issues a one-time
 * code bound to that record; the owner redeems it and the record is attached to the owner's account.
 * Everything goes through the functions of migration 0015; only the hash of a code is stored.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export interface PassPreview { record_id: string; mark_text: I18nText | null; registry_code: string; number: string | null; agency_name: I18nText; expires_at: string }
export interface PassState { expires_at: string; sent_to: string | null; redeemed_at: string | null; created_at: string }

export async function issuePass(s: Session, recordId: string, sentTo: string | null): Promise<string> {
  return rows<{ code: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_pass_issue(${recordId}::uuid, ${sentTo}::citext) AS code`)))[0]!.code;
}
/** The latest pass this account issued for the record (never the code itself). */
export async function latestPass(s: Session, recordId: string): Promise<PassState | null> {
  return rows<PassState>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT expires_at, sent_to, redeemed_at, created_at FROM core.owner_pass
     WHERE record_id = ${recordId}::uuid AND issued_by_account_id = ${s.accountId}::uuid ORDER BY created_at DESC LIMIT 1`)))[0] ?? null;
}
export async function passPreview(code: string): Promise<PassPreview | null> {
  return rows<PassPreview>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_pass_preview(${code})`)))[0] ?? null;
}
export async function redeemPass(s: Session, code: string): Promise<string> {
  return rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_pass_redeem(${code}) AS id`)))[0]!.id;
}
