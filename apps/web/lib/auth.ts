import { NextResponse } from "next/server";
import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { isLocale, type Locale } from "@meesam/i18n";
import { db } from "./db";
import { newToken, sha256 } from "./session";
import { appUrl } from "./mail";

export const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function localeOf(form: FormData): Locale {
  const v = String(form.get("locale") ?? "");
  return isLocale(v) ? v : "en";
}

export function text(form: FormData, key: string, max = 200): string {
  const v = form.get(key);
  return typeof v === "string" ? v.trim().slice(0, max) : "";
}

/**
 * Redirects to a path on the public origin. Behind Railway + Cloudflare the request URL the server
 * sees is the container's (0.0.0.0:3000), so the origin comes from APP_URL, else the forwarded headers.
 */
export function redirectTo(req: Request, path: string, params?: Record<string, string>): NextResponse {
  const url = new URL(path, publicOrigin(req));
  for (const [k, v] of Object.entries(params ?? {})) url.searchParams.set(k, v);
  return NextResponse.redirect(url, 303);
}

export function publicOrigin(req: Request): string {
  if (process.env.APP_URL) return appUrl();
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host");
  const proto = req.headers.get("x-forwarded-proto") ?? "https";
  return host ? `${proto}://${host}` : req.url;
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

/** Is the user's account verified? Used by the e-mail confirmation page (an invited owner is verified at that step). */
export async function accountVerifiedOf(userId: string): Promise<boolean> {
  const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.fn_user_account_verified(${userId}::uuid) AS ok`))) as unknown as Array<{ ok: boolean }>;
  return Boolean(rows[0]?.ok);
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

/** Failed sign-ins from one network address in the last 15 minutes, across all e-mail addresses (migration 0072). */
export async function recentFailuresFromIp(ip: string | null): Promise<number> {
  if (!ip) return 0;
  const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.fn_recent_failures_ip(${ip}::inet) AS n`))) as unknown as Array<{ n: number }>;
  return Number(rows[0]?.n ?? 0);
}

/**
 * Limits on the forms that send e-mail or create accounts (migration 0072). Each entry is a key, the most events
 * allowed, and the window in minutes; every key is counted, and the answer is "allowed" only when all are within
 * their limit. A check that cannot be made (database trouble) allows the request: a limit must never lock people out.
 */
export async function withinLimits(limits: Array<[key: string | null, max: number, minutes: number]>): Promise<boolean> {
  try {
    let ok = true;
    for (const [key, max, minutes] of limits) {
      if (!key) continue;
      const r = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT platform.fn_rate_hit(${key}, ${max}::int, make_interval(mins => ${minutes}::int)) AS ok`))) as unknown as Array<{ ok: boolean }>;
      if (r[0]?.ok === false) ok = false;
    }
    return ok;
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "limits", message: (e as Error).message }));
    return true;
  }
}
