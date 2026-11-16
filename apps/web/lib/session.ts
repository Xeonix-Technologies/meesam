import { createHash, randomBytes } from "node:crypto";
import { cookies, headers } from "next/headers";
import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import type { Locale } from "@meesam/i18n";
import { db } from "./db";

export const SESSION_COOKIE = "msm_session";
const SESSION_DAYS = 30;

export interface Session {
  sessionId: string;
  userId: string;
  accountId: string;
  email: string;
  userName: string;
  role: "company_admin" | "tm_manager" | "agency_admin" | "agent" | "viewer";
  locale: Locale;
  accountKind: "owner_individual" | "owner_company" | "agency_office";
  accountName: Record<string, string>;
  verificationStatus: "pending_email" | "pending_review" | "verified" | "rejected";
  logoKey: string | null;
}

export function newToken(): { token: string; hash: Buffer } {
  const token = randomBytes(32).toString("base64url");
  return { token, hash: sha256(token) };
}

export function sha256(value: string): Buffer {
  return createHash("sha256").update(value).digest();
}

export async function requestMeta(): Promise<{ ip: string | null; userAgent: string | null }> {
  const h = await headers();
  const forwarded = h.get("cf-connecting-ip") ?? h.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null;
  return { ip: forwarded && /^[0-9a-f.:]+$/i.test(forwarded) ? forwarded : null, userAgent: h.get("user-agent") };
}

export async function createSession(userId: string): Promise<void> {
  const { token, hash } = newToken();
  const meta = await requestMeta();
  await withRole(db(), "meesam_app", (tx) =>
    tx.execute(sql`SELECT core.sp_session_create(${userId}::uuid, ${hash}, ${`${SESSION_DAYS} days`}::interval, ${meta.ip}::inet, ${meta.userAgent})`),
  );
  const jar = await cookies();
  jar.set(SESSION_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: SESSION_DAYS * 24 * 3600,
  });
}

export async function destroySession(): Promise<void> {
  const jar = await cookies();
  const token = jar.get(SESSION_COOKIE)?.value;
  if (token) {
    await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_session_revoke(${sha256(token)})`));
  }
  jar.delete(SESSION_COOKIE);
}

/** The signed-in user, or null. Cheap enough to call per request (one indexed lookup). */
export async function getSession(): Promise<Session | null> {
  const jar = await cookies();
  const token = jar.get(SESSION_COOKIE)?.value;
  if (!token) return null;
  const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_session(${sha256(token)})`))) as unknown as Array<Record<string, unknown>>;
  const r = rows[0];
  if (!r) return null;
  return {
    sessionId: String(r.session_id),
    userId: String(r.user_id),
    accountId: String(r.account_id),
    email: String(r.email),
    userName: String(r.user_name),
    role: r.role as Session["role"],
    locale: (r.locale as Locale) ?? "en",
    accountKind: r.account_kind as Session["accountKind"],
    accountName: (r.account_name as Record<string, string>) ?? {},
    verificationStatus: r.verification_status as Session["verificationStatus"],
    logoKey: (r.logo_key as string | null) ?? null,
  };
}
