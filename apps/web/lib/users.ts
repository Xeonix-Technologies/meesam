import { sql } from "drizzle-orm";
import { withAccount, withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import { sha256, type Session } from "./session";

/**
 * Users and roles inside an account (System Description Section 3; items 38 and 39). Reads go through
 * row-level security; every change goes through the database functions of migration 0011, which check
 * that the caller is the account's administrator.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export type UserRole = Session["role"];
export const OWNER_ROLES: UserRole[] = ["company_admin", "tm_manager"];
// Founder ruling 18 Nov 2026: the Viewer role is not offered for now (it may return later). The database still
// knows the role, and an existing Viewer stays read-only until an administrator changes the role.
export const AGENCY_ROLES: UserRole[] = ["agency_admin", "agent"];
export const rolesFor = (kind: Session["accountKind"]): UserRole[] => (kind === "agency_office" ? AGENCY_ROLES : kind === "owner_company" ? OWNER_ROLES : []);
export const isAccountAdmin = (s: Session) => s.role === "company_admin" || s.role === "agency_admin";

export interface AccountUser { id: string; email: string; name: string; role: UserRole; locale: string; status: "invited" | "active" | "suspended" | "removed"; last_login_at: string | null; created_at: string }

export async function listUsers(s: Session): Promise<AccountUser[]> {
  return rows<AccountUser>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT id, email, name, role, locale, status, last_login_at, created_at FROM core.app_user
     WHERE status <> 'removed' ORDER BY (status = 'invited') DESC, created_at`)));
}

export async function inviteUser(s: Session, p: { email: string; name: string; role: string; locale: string }): Promise<string> {
  const r = rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT core.fn_user_invite(${p.email}::citext, ${p.name}, ${p.role}::core.user_role, ${p.locale}) AS id`)));
  return r[0]!.id;
}
/** The user id when it is an open invitation of this account (for sending the invitation again), else null. */
export async function openInvitation(s: Session, userId: string): Promise<AccountUser | null> {
  return withAccount(db(), ctx(s), async (tx) => {
    const ok = rows<{ id: string | null }>(await tx.execute(sql`SELECT core.fn_user_invited(${userId}::uuid) AS id`))[0]?.id;
    if (!ok) return null;
    return rows<AccountUser>(await tx.execute(sql`SELECT id, email, name, role, locale, status, last_login_at, created_at FROM core.app_user WHERE id = ${userId}::uuid`))[0] ?? null;
  });
}
export const setUserRole = (s: Session, userId: string, role: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_user_set_role(${userId}::uuid, ${role}::core.user_role)`));
export const setUserStatus = (s: Session, userId: string, status: "active" | "suspended" | "removed") =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_user_set_status(${userId}::uuid, ${status}::core.user_status)`));

export async function invitePreview(token: string): Promise<{ user_name: string; email: string; account_name: I18nText } | null> {
  return rows<{ user_name: string; email: string; account_name: I18nText }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_invite_preview(${sha256(token)})`)))[0] ?? null;
}
export async function acceptInvite(token: string, passwordHash: string): Promise<string | null> {
  return rows<{ id: string | null }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_accept_invite(${sha256(token)}, ${passwordHash}) AS id`)))[0]?.id ?? null;
}
