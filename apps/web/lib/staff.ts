import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Staff roles (Staff Services and Pages v0.1, Section 2): system_admin, watch_lead, publication_reviewer.
 * The first System Administrator is named in configuration (SYSTEM_ADMIN_EMAILS, comma-separated): a signed-in,
 * verified user whose e-mail is listed there is granted the role on first entry. Everyone after that is
 * granted or removed from inside the System Admin.
 */
export type StaffRole = "system_admin" | "watch_lead" | "publication_reviewer";
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export async function staffRoles(s: Session): Promise<StaffRole[]> {
  const read = async () => rows<{ roles: StaffRole[] }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT platform.fn_staff_roles(${s.userId}::uuid) AS roles`)))[0]?.roles ?? [];
  let roles = await read();
  if (!roles.includes("system_admin")) {
    const listed = (process.env.SYSTEM_ADMIN_EMAILS ?? "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
    if (listed.includes(s.email.toLowerCase())) {
      await withRole(db(), "meesam_admin", (tx) => tx.execute(sql`CALL platform.sp_grant_staff(${s.userId}::uuid, 'system_admin', NULL, 'bootstrap: SYSTEM_ADMIN_EMAILS')`));
      roles = await read();
    }
  }
  return roles;
}

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
