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

/**
 * Who a valid pass is addressed to, seen from one e-mail address: "named" (the agency had it sent there),
 * "open" (no address given), "other" (sent elsewhere); null for a code that is not valid (migration 0017).
 */
export async function passAddressee(code: string, email: string): Promise<"named" | "open" | "other" | null> {
  const r = rows<{ a: "named" | "open" | "other" | null }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.fn_pass_addressee(${code}, ${email}::citext) AS a`)));
  return r[0]?.a ?? null;
}

/** Whether this agency can take the record back now (it issued the redeemed pass and still manages the record; migration 0019). */
export async function canTakeBack(s: Session, recordId: string): Promise<boolean> {
  return Boolean(rows<{ ok: boolean }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_pass_can_take_back(${recordId}::uuid) AS ok`)))[0]?.ok);
}
/** Takes the record back into the agency's own account; returns the owner's users to tell by e-mail. */
export async function takeBack(s: Session, recordId: string): Promise<Array<{ email: string; name: string; locale: string }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT email, name, locale FROM core.fn_pass_take_back(${recordId}::uuid)`)));
}
