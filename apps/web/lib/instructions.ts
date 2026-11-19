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
  /** file names of the documents the sender attached (0032): the owner's legal request and the power of attorney */
  legal_doc_name: string | null; poa_doc_name: string | null;
  /** an agency's instruction: is the instructed office named to the owner? */
  named_to_owner: boolean; from_is_owner: boolean;
}

export async function listInstructions(s: Session, recordId?: string): Promise<InstructionRow[]> {
  return rows<InstructionRow>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT * FROM core.fn_instruction_list(${recordId ?? null}::uuid)`)));
}
export async function requestInstruction(s: Session, recordId: string, toAccountId: string | null, toEmail: string | null, message: string, legalDocId: string | null = null, poaDocId: string | null = null): Promise<string> {
  return rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT core.fn_instruction_request(${recordId}::uuid, ${toAccountId}::uuid, ${toEmail}::citext, ${message || null}::text, ${legalDocId}::uuid, ${poaDocId}::uuid) AS id`)))[0]!.id;
}
/** One of the two documents attached to an instruction; the database decides whether the caller may open it. */
export async function instructionDoc(s: Session, id: string, which: "legal" | "poa"): Promise<{ object_key: string; file_name: string } | null> {
  const r = rows<{ object_key: string | null; file_name: string | null }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT object_key, file_name FROM core.fn_instruction_doc(${id}::uuid, ${which})`)))[0];
  return r?.object_key ? { object_key: r.object_key, file_name: r.file_name ?? "document" } : null;
}
/** The instructing agency names, or stops naming, the instructed office to the owner (item 26). */
export const nameToOwner = (s: Session, id: string, named: boolean) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_instruction_name_to_owner(${id}::uuid, ${named})`));
/** For the owner: the offices its agencies named to it on this record. */
export async function namedOffices(s: Session, recordId: string): Promise<Array<{ office: I18nText; country: string | null; through: I18nText }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT office, country, through FROM core.fn_record_named_offices(${recordId}::uuid)`)));
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

/** Instruct an office named by its e-mail address: sent at once if the office is on Meesam, otherwise an invitation that waits (0034). */
export async function instructByEmail(s: Session, recordId: string, email: string, message: string, legalDocId: string | null, poaDocId: string | null): Promise<{ outcome: "request" | "invited"; instruction_id: string | null; invite_id: string | null }> {
  return rows<{ outcome: "request" | "invited"; instruction_id: string | null; invite_id: string | null }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT outcome, instruction_id, invite_id FROM core.fn_instruction_by_email(${recordId}::uuid, ${email}::citext, ${message || null}::text, ${legalDocId}::uuid, ${poaDocId}::uuid)`)))[0]!;
}
export interface InstructionInviteRow { id: string; record_id: string; email: string; created_at: string; mark_text: I18nText | null; registry_code: string; number: string | null }
/** This account's invitations still waiting for the office to join Meesam. */
export async function listInstructionInvites(s: Session, recordId?: string): Promise<InstructionInviteRow[]> {
  return rows<InstructionInviteRow>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT i.id, i.record_id, i.email::text AS email, i.created_at, r.mark_text, g.code AS registry_code, COALESCE(r.registration_no, r.application_no) AS number
      FROM core.instruction_invite i JOIN core.record r ON r.id = i.record_id JOIN registry.registry g ON g.id = r.registry_id
     WHERE i.status = 'pending' AND (${recordId ?? null}::uuid IS NULL OR i.record_id = ${recordId ?? null}::uuid) ORDER BY i.created_at DESC`)));
}
export const withdrawInstructionInvite = (s: Session, id: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_instruction_invite_withdraw(${id}::uuid)`));
