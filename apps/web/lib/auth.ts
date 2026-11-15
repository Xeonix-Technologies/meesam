import { NextResponse } from "next/server";
import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { isLocale, type Locale } from "@meesam/i18n";
import { db } from "./db";
import { newToken, sha256 } from "./session";

export const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function localeOf(form: FormData): Locale {
  const v = String(form.get("locale") ?? "");
  return isLocale(v) ? v : "en";
}

export function text(form: FormData, key: string, max = 200): string {
  const v = form.get(key);
  return typeof v === "string" ? v.trim().slice(0, max) : "";
}

export function redirectTo(req: Request, path: string, params?: Record<string, string>): NextResponse {
  const url = new URL(path, req.url);
  for (const [k, v] of Object.entries(params ?? {})) url.searchParams.set(k, v);
  return NextResponse.redirect(url, 303);
}

export async function issueToken(userId: string, purpose: "email_verify" | "password_reset" | "invite", ttl: string): Promise<string> {
  const { token, hash } = newToken();
  await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_issue_token(${userId}::uuid, ${purpose}::core.token_purpose, ${hash}, ${ttl}::interval)`));
  return token;
}

export async function consumeToken(token: string, purpose: "email_verify" | "password_reset" | "invite"): Promise<string | null> {
  const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_consume_token(${sha256(token)}, ${purpose}::core.token_purpose) AS user_id`))) as unknown as Array<{ user_id: string | null }>;
  return rows[0]?.user_id ?? null;
}

export interface LoginRow {
  user_id: string;
  account_id: string;
  password_hash: string | null;
  user_status: "invited" | "active" | "suspended" | "removed";
  verification_status: "pending_email" | "pending_review" | "verified" | "rejected";
  locale: string;
}

export async function userForLogin(email: string): Promise<LoginRow | null> {
  const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_user_for_login(${email}::citext)`))) as unknown as LoginRow[];
  return rows[0] ?? null;
}

export async function recordAttempt(email: string, ok: boolean, ip: string | null, userAgent: string | null): Promise<void> {
  await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_login_attempt(${email}::citext, ${ok}, ${ip}::inet, ${userAgent})`));
}

export async function recentFailures(email: string): Promise<number> {
  const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.fn_recent_failures(${email}::citext) AS n`))) as unknown as Array<{ n: number }>;
  return Number(rows[0]?.n ?? 0);
}
