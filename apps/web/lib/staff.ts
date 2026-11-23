import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Staff roles (Staff Services and Pages v0.1, Section 2): system_admin, watch_lead, publication_reviewer.
 * Staff use a separate staff login: a user of the internal staff account, invited from System Admin → Staff
 * (migration 0025). The first one of an environment comes from SYSTEM_ADMIN_EMAILS (see bootstrapStaffAdmin).
 */
export type StaffRole = "system_admin" | "watch_lead" | "publication_reviewer";
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export const STAFF_ROLES: StaffRole[] = ["system_admin", "watch_lead", "publication_reviewer"];
const listedAdmins = () => (process.env.SYSTEM_ADMIN_EMAILS ?? "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);

/** The staff roles of the signed-in user. Roles are given inside the System Admin (or by the bootstrap below), never claimed here. */
export async function staffRoles(s: Session): Promise<StaffRole[]> {
  return rows<{ roles: StaffRole[] }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT platform.fn_staff_roles(${s.userId}::uuid) AS roles`)))[0]?.roles ?? [];
}

/** Whether the address is named as a first System Administrator of this environment (SYSTEM_ADMIN_EMAILS). */
export const isListedAdmin = (email: string): boolean => listedAdmins().includes(email.toLowerCase());

/**
 * First System Administrator of an environment (Founder ruling 18 Nov 2026: a separate staff login). An address
 * named in SYSTEM_ADMIN_EMAILS that has no login yet gets a staff login, invited by e-mail, when a password
 * reset is asked for that address: only someone who controls the mailbox can complete it. Returns the new
 * user id, or null when the address is not listed or already has a login.
 */
export async function bootstrapStaffAdmin(email: string): Promise<string | null> {
  if (!listedAdmins().includes(email.toLowerCase())) return null;
  try {
    const r = rows<{ id: string }>(await withRole(db(), "meesam_admin", (tx) => tx.execute(sql`SELECT platform.fn_staff_invite(${email}::citext, ${email.split("@")[0] ?? "Admin"}, 'system_admin', NULL) AS id`)));
    return r[0]?.id ?? null;
  } catch (e) {
    // usually "the address already has a login"; any other reason must be seen, not swallowed
    const err = e as { code?: string; cause?: { code?: string; message?: string }; message?: string };
    console.error(JSON.stringify({ level: "error", at: "staff.bootstrap", message: `first administrator not created: ${(err.cause?.message ?? err.message ?? "").slice(0, 160)}`, code: err.cause?.code ?? err.code ?? null }));
    return null;
  }
}

export interface StaffMember { id: string; email: string; name: string; status: string; last_login_at: string | null; totp: boolean; roles: StaffRole[]; separate_login: boolean; account_name: I18nText }
export async function listStaff(): Promise<StaffMember[]> {
  return rows<StaffMember>(await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`SELECT * FROM platform.v_staff ORDER BY separate_login DESC, created_at`)));
}
export async function inviteStaff(by: Session, email: string, name: string, role: StaffRole): Promise<string> {
  return rows<{ id: string }>(await withRole(db(), "meesam_admin", (tx) => tx.execute(sql`SELECT platform.fn_staff_invite(${email}::citext, ${name}, ${role}, ${by.userId}::uuid) AS id`)))[0]!.id;
}
/** Gives or takes one role of a staff member (a person may hold several; the last role and the last System Administrator stay). */
export const setStaffRole = (by: Session, userId: string, role: StaffRole, on: boolean) =>
  withRole(db(), "meesam_admin", (tx) => tx.execute(sql`SELECT platform.fn_staff_role_set(${userId}::uuid, ${role}, ${on}, ${by.userId}::uuid)`));

export const removeStaff = (userId: string) => withRole(db(), "meesam_admin", (tx) => tx.execute(sql`SELECT platform.fn_staff_remove(${userId}::uuid)`));

export interface AdminAccount {
  id: string; kind: string; name: I18nText; country: string; city: string | null; registration_ref: string | null; licence_no: string | null;
  contact: Record<string, string> | null; verification_status: string; verified_at: string | null; review_note: string | null; created_at: string;
  users: Array<{ id: string; name: string; email: string; role: string; status: string }> | null;
  licences: Array<{ registry: string; ref: string; verified_at: string | null }> | null; records: number;
}

export async function listAdminAccounts(): Promise<AdminAccount[]> {
  return rows<AdminAccount>(await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`
    SELECT * FROM platform.v_admin_account ORDER BY (verification_status = 'pending_review') DESC, created_at DESC LIMIT 500`)));
}

/** Approves or rejects an account (item 4.2: verification before activation). Returns the users to notify. */
export async function reviewAccount(by: Session, accountId: string, approve: boolean, note: string): Promise<Array<{ email: string; name: string; locale: string }>> {
  return withRole(db(), "meesam_staff", async (tx) => {
    await tx.execute(sql`CALL core.sp_review_account(${accountId}::uuid, ${approve}, 'staff', ${by.userId}::uuid, ${note || null})`);
    return rows<{ email: string; name: string; locale: string }>(await tx.execute(sql`SELECT email, name, locale FROM core.app_user WHERE account_id = ${accountId}::uuid AND status = 'active'`));
  });
}

/**
 * Sends the queued notices to the staff (migration 0028: an owner verified by an agency's invitation, no review needed).
 * Called after the actions that can queue one; a failure is logged and never undoes the action.
 */
export async function flushStaffNotices(): Promise<void> {
  try {
    const list = rows<{ email: string; name: string; locale: string; kind: string; payload: { owner?: Record<string, string>; email?: string; agency?: Record<string, string>; kind?: string } }>(
      await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`SELECT email::text AS email, name, locale, kind, payload FROM platform.fn_staff_notices_take()`)));
    const { sendStaffInviteVerifiedMail } = await import("./mail");
    await Promise.allSettled(list.map((n) => sendStaffInviteVerifiedMail(n.email, n.name, n.locale === "ar" ? "ar" : "en", n.payload.owner ?? {}, n.payload.email ?? "", n.payload.agency ?? {})));
  } catch (e) { console.error(JSON.stringify({ level: "error", at: "staff.notices", message: (e as Error).message })); }
}

/**
 * Sends the e-mail that tells an owner an agency's invitation is now a request in their account (migration 0029;
 * the inviting office can switch it off). Returns the appointments mailed. A failure is logged, never thrown.
 */
export async function flushInviteRequestMails(): Promise<string[]> {
  try {
    const list = rows<{ email: string; name: string; locale: string; account_id: string; appointment_id: string; agency: Record<string, string> | null; note: string | null }>(
      await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`SELECT email::text AS email, name, locale, account_id, appointment_id, agency, note FROM platform.fn_invite_request_mails_take()`)));
    const { sendAppointmentMail } = await import("./mail");
    const { pickText } = await import("@meesam/i18n");
    await Promise.allSettled(list.map((n) => { const l = n.locale === "ar" ? "ar" : "en";
      return sendAppointmentMail(n.email, n.name, l, "requested", pickText(n.agency ?? {}, l), "agencies", n.note ?? "", n.account_id); }));
    return [...new Set(list.map((n) => n.appointment_id))];
  } catch (e) { console.error(JSON.stringify({ level: "error", at: "staff.inviteMails", message: (e as Error).message })); return []; }
}

/** Tells a newly verified agency office by e-mail that an instruction it was invited for is waiting in its account (0034). */
export async function flushInstructionInviteMails(): Promise<void> {
  try {
    const list = rows<{ email: string; name: string; locale: string; account_id: string; sender: Record<string, string> | null; mark_text: Record<string, string> | null; number: string | null; registry_code: string; note: string | null }>(
      await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`SELECT email::text AS email, name, locale, account_id, sender, mark_text, number, registry_code, note FROM platform.fn_instruction_invite_mails_take()`)));
    const { sendInstructionMail } = await import("./mail");
    const { pickText } = await import("@meesam/i18n");
    await Promise.allSettled(list.map((n) => { const l = n.locale === "ar" ? "ar" : "en";
      return sendInstructionMail(n.email, n.name, l, "requested", pickText(n.sender ?? {}, l), `${pickText(n.mark_text ?? {}, l) || n.number || "—"} (${n.registry_code})`, n.note ?? "", n.account_id); }));
  } catch (e) { console.error(JSON.stringify({ level: "error", at: "staff.instructionInviteMails", message: (e as Error).message })); }
}

/** Second copy of the database (plan item A7; migration 0062): the runs the worker recorded, newest first. */
export interface BackupRun {
  id: string; started_at: string; finished_at: string | null; ok: boolean | null; trigger: string; requested_by_name: string | null;
  bytes: string | null; entries: number | null; restore_ok: boolean | null; restore: { seconds?: number; error?: string; mismatch?: boolean; counts?: { restored?: { tables?: number } } } | null; error: string | null; deleted_at: string | null;
}
export async function listBackups(): Promise<BackupRun[]> {
  return rows<BackupRun>(await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`
    SELECT b.id, b.started_at, b.finished_at,
           -- a run with no outcome after two hours was interrupted (the worker restarted in the middle)
           CASE WHEN b.ok IS NULL AND b.started_at < now() - interval '2 hours' THEN false ELSE b.ok END AS ok, b.trigger, (SELECT u.name FROM core.app_user u WHERE u.id = b.requested_by) AS requested_by_name,
           b.bytes::text, b.entries, b.restore_ok, b.restore,
           CASE WHEN b.ok IS NULL AND b.started_at < now() - interval '2 hours' THEN 'Interrupted before it finished' ELSE b.error END AS error, b.deleted_at
      FROM platform.backup_run b ORDER BY b.started_at DESC LIMIT 60`)));
}
/** A system administrator asks for a copy now, with or without a restore test; the database checks the role. */
export const requestBackup = (by: Session, restoreTest: boolean) =>
  withRole(db(), "meesam_staff", async (tx) => {
    await tx.execute(sql`SELECT set_config('meesam.user_id', ${by.userId}, true)`);
    await tx.execute(sql`SELECT platform.fn_backup_request(${restoreTest})`);
  });

/** Feedback written by signed-in users (ruling R11; migration 0077), newest first. */
export interface FeedbackItem { id: string; created_at: string; body: string; page: string | null; user_name: string | null; account_name: I18nText | null }
export async function listFeedback(): Promise<FeedbackItem[]> {
  return rows<FeedbackItem>(await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`
    SELECT f.id, f.created_at, f.body, f.page, (SELECT u.name FROM core.app_user u WHERE u.id = f.user_id) AS user_name,
           (SELECT a.name FROM core.account a WHERE a.id = f.account_id) AS account_name
      FROM platform.feedback f ORDER BY f.created_at DESC LIMIT 200`)));
}
