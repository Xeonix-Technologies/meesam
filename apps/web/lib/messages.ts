import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Per-record message thread between the owner and the holding agency (item 39 (vi): text only, each message
 * a timeline entry). Reads go through row-level security; posting goes through fn_message_post (migration 0014).
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export interface RecordMessage { id: string; body: string; created_at: string; author_name: string; author_account: I18nText; mine: boolean; other_account_id: string; other_account: I18nText }

export async function listMessages(s: Session, recordId: string): Promise<RecordMessage[]> {
  return rows<RecordMessage>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT m.id, m.body, m.created_at, COALESCE(m.author_name, '') AS author_name, a.name AS author_account, (m.author_account_id = ${s.accountId}::uuid) AS mine,
           CASE WHEN t.owner_account_id = ${s.accountId}::uuid THEN t.agency_account_id ELSE t.owner_account_id END AS other_account_id,
           (SELECT o.name FROM core.account o WHERE o.id = CASE WHEN t.owner_account_id = ${s.accountId}::uuid THEN t.agency_account_id ELSE t.owner_account_id END) AS other_account
      FROM core.message m JOIN core.message_thread t ON t.id = m.thread_id
      JOIN core.account a ON a.id = m.author_account_id
     WHERE t.record_id = ${recordId}::uuid ORDER BY m.created_at`)));
}

/** Messages from the other side that this account has not opened yet, on one record. */
export async function unreadOnRecord(s: Session, recordId: string): Promise<number> {
  return Number(rows<{ n: number }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT count(*)::int AS n FROM core.message m JOIN core.message_thread t ON t.id = m.thread_id
     WHERE t.record_id = ${recordId}::uuid AND m.author_account_id <> ${s.accountId}::uuid
       AND m.created_at > COALESCE(CASE WHEN t.owner_account_id = ${s.accountId}::uuid THEN t.owner_read_at ELSE t.agency_read_at END, '-infinity'::timestamptz)`)))[0]?.n ?? 0);
}

/** Records with unread messages, for the dashboard and the side navigation. */
export async function unreadByRecord(s: Session): Promise<Array<{ record_id: string; n: number; mark_text: I18nText | null }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT t.record_id, count(*)::int AS n, (SELECT r.mark_text FROM core.record r WHERE r.id = t.record_id) AS mark_text
      FROM core.message m JOIN core.message_thread t ON t.id = m.thread_id
     WHERE m.author_account_id <> ${s.accountId}::uuid
       AND m.created_at > COALESCE(CASE WHEN t.owner_account_id = ${s.accountId}::uuid THEN t.owner_read_at ELSE t.agency_read_at END, '-infinity'::timestamptz)
     GROUP BY t.record_id ORDER BY max(m.created_at) DESC`)));
}

/** Posts on the thread with one agency (`agencyId`; needed when the owner has more than one holding agency) or with the only other side. */
export async function postMessage(s: Session, recordId: string, body: string, agencyId: string | null = null): Promise<string> {
  return rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_message_post(${recordId}::uuid, ${body}, ${agencyId}::uuid) AS id`)))[0]!.id;
}
/** The agencies managing the record now, as the owner sees them (an agency sees only itself). */
/** Whom this account can write to on the record's thread: for the owner, the agencies on it; for such an agency, itself (0029). */
export async function holdingAgencies(s: Session, recordId: string): Promise<Array<{ id: string; name: I18nText }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT id, name FROM core.fn_message_parties(${recordId}::uuid)`)));
}
export const markThreadRead = (s: Session, recordId: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_thread_mark_read(${recordId}::uuid)`));
export async function messageRecipients(s: Session, messageId: string): Promise<Array<{ email: string; name: string; locale: string; account_id: string }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT email, name, locale, account_id FROM core.fn_message_recipients(${messageId}::uuid)`)));
}
