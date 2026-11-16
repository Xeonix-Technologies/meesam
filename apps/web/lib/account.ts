import { sql } from "drizzle-orm";
import { withAccount, withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";
import { hashPassword, verifyPassword } from "./password";
import { createSession } from "./session";

const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export interface AccountSettings {
  kind: string; logo_key: string | null; name: I18nText; country: string; city: string | null; registration_ref: string | null; licence_no: string | null;
  contact: { mobile?: string; phone?: string; website?: string; address?: string }; verification_status: string;
  user_name: string; email: string; locale: string; role: string;
}

/** Account and user details (Owner/Agency 3.1 "Account"): edits are audited by the database and apply to the signed-in account only (RLS). */
export async function getAccountSettings(s: Session): Promise<AccountSettings | null> {
  const r = rows<AccountSettings>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT a.kind, a.logo_key, a.name, a.country, a.city, a.registration_ref, a.licence_no, a.contact, a.verification_status,
           u.name AS user_name, u.email, u.locale, u.role
      FROM core.account a JOIN core.app_user u ON u.account_id = a.id
     WHERE a.id = ${s.accountId}::uuid AND u.id = ${s.userId}::uuid`)))[0];
  return r ?? null;
}

export async function updateAccountProfile(s: Session, p: { name: I18nText; country: string; city: string | null; contact: Record<string, string> }): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    UPDATE core.account SET name = ${JSON.stringify(p.name)}::jsonb, country = ${p.country}, city = ${p.city},
                            contact = contact || ${JSON.stringify(p.contact)}::jsonb
     WHERE id = ${s.accountId}::uuid`));
}

export async function setAccountLogo(s: Session, key: string | null): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE core.account SET logo_key = ${key} WHERE id = ${s.accountId}::uuid`));
}

export async function accountLogoKey(s: Session): Promise<string | null> {
  const r = rows<{ logo_key: string | null }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT logo_key FROM core.account WHERE id = ${s.accountId}::uuid`)))[0];
  return r?.logo_key ?? null;
}

export async function updateUserProfile(s: Session, p: { name: string; locale: string }): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE core.app_user SET name = ${p.name}, locale = ${p.locale} WHERE id = ${s.userId}::uuid`));
}

/** Changes the password after checking the current one; every session is revoked by the procedure, then a fresh one is opened here. */
export async function changePassword(s: Session, current: string, next: string): Promise<"ok" | "wrong_current"> {
  const r = rows<{ password_hash: string | null }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT password_hash FROM core.app_user WHERE id = ${s.userId}::uuid`)))[0];
  if (!(await verifyPassword(current, r?.password_hash))) return "wrong_current";
  const hash = await hashPassword(next);
  await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_set_password(${s.userId}::uuid, ${hash})`));
  await createSession(s.userId);
  return "ok";
}
