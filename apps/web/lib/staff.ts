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
  } catch { return null; }        // the address already has a login
}

export interface StaffMember { id: string; email: string; name: string; status: string; last_login_at: string | null; totp: boolean; roles: StaffRole[]; separate_login: boolean; account_name: I18nText }
export async function listStaff(): Promise<StaffMember[]> {
  return rows<StaffMember>(await withRole(db(), "meesam_staff", (tx) => tx.execute(sql`SELECT * FROM platform.v_staff ORDER BY separate_login DESC, created_at`)));
}
export async function inviteStaff(by: Session, email: string, name: string, role: StaffRole): Promise<string> {
  return rows<{ id: string }>(await withRole(db(), "meesam_admin", (tx) => tx.execute(sql`SELECT platform.fn_staff_invite(${email}::citext, ${name}, ${role}, ${by.userId}::uuid) AS id`)))[0]!.id;
}
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
