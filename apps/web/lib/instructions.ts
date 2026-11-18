import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Cross-border instructions between agency offices (System Description 4.4 link 3; migration 0027).
 * Every read and change goes through database functions that check who is calling; the owner of the mark
 * is not shown the instructed office (item 26).
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export interface InstructionRow {
  id: string; status: "requested" | "active" | "declined" | "ended"; direction: "sent" | "received";
  record_id: string; mark_text: I18nText | null; registry_code: string; number: string | null;
  other_account_id: string; other_name: I18nText; other_country: string | null; owner_name: I18nText | null;
  message: string | null; decline_note: string | null; created_at: string; accepted_at: string | null; ended_at: string | null;
  /** active, and the instructing office still holds the record */
  in_force: boolean;
}

export async function listInstructions(s: Session, recordId?: string): Promise<InstructionRow[]> {
  if (s.accountKind !== "agency_office") return [];
  return rows<InstructionRow>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT * FROM core.fn_instruction_list(${recordId ?? null}::uuid)`)));
}
export async function requestInstruction(s: Session, recordId: string, toAccountId: string | null, toEmail: string | null, message: string): Promise<string> {
  return rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT core.fn_instruction_request(${recordId}::uuid, ${toAccountId}::uuid, ${toEmail}::citext, ${message || null}::text) AS id`)))[0]!.id;
}
export const respondInstruction = (s: Session, id: string, accept: boolean, note: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_instruction_respond(${id}::uuid, ${accept}, ${note || null}::text)`));
export const endInstruction = (s: Session, id: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_instruction_end(${id}::uuid)`));
/** The other office's users who are told by e-mail. */
export async function instructionRecipients(s: Session, id: string): Promise<Array<{ email: string; name: string; locale: string; account_id: string }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT email::text AS email, name, locale, account_id FROM core.fn_instruction_recipients(${id}::uuid)`)));
}
/** Instructions waiting for this office's answer; shown on the side navigation. */
export async function pendingInstructionCount(s: Session): Promise<number> {
  if (s.accountKind !== "agency_office") return 0;
  return Number(rows<{ n: number }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT count(*)::int AS n FROM core.fn_instruction_list() WHERE direction = 'received' AND status = 'requested'`)))[0]?.n ?? 0);
}
