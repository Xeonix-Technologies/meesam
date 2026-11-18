import { createHmac, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";
import { sql } from "drizzle-orm";
import { withAccount, withRole } from "@meesam/db";
import { db } from "./db";
import { newToken, sha256, type Session } from "./session";

/**
 * Two-factor sign-in (Founder ruling 18 Nov 2026): an authenticator-app code (TOTP, RFC 6238: SHA-1, 6 digits,
 * 30 seconds) and a code sent by e-mail. Required for Meesam staff and account administrators, optional for
 * the rest. The database keeps the secret and the sign-in challenge out of the app role's reach (migration
 * 0024); this module does the arithmetic and talks to those functions.
 */
export const CHALLENGE_COOKIE = "ms_2fa";
const STEP = 30;
const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export function newSecret(): string {
  const bytes = randomBytes(20);
  let bits = "", out = "";
  for (const b of bytes) bits += b.toString(2).padStart(8, "0");
  for (let i = 0; i < bits.length; i += 5) out += B32[parseInt(bits.slice(i, i + 5).padEnd(5, "0"), 2)];
  return out;
}
function decodeBase32(s: string): Buffer {
  let bits = "";
  for (const ch of s.toUpperCase().replace(/[^A-Z2-7]/g, "")) bits += B32.indexOf(ch).toString(2).padStart(5, "0");
  const out: number[] = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(out);
}
export function totpAt(secret: string, step: number): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const h = createHmac("sha1", decodeBase32(secret)).update(counter).digest();
  const o = h[h.length - 1]! & 0x0f;
  const n = ((h[o]! & 0x7f) << 24) | (h[o + 1]! << 16) | (h[o + 2]! << 8) | h[o + 3]!;
  return String(n % 1_000_000).padStart(6, "0");
}
/** The time step a code is valid for (this one, the one before or the one after), or null. `after` refuses a step already used. */
export function matchTotp(secret: string, code: string, after: number | null = null, now = Date.now()): number | null {
  const clean = code.replace(/\D/g, "");
  if (clean.length !== 6) return null;
  const current = Math.floor(now / 1000 / STEP);
  for (const step of [current, current - 1, current + 1]) {
    if (after !== null && step <= after) continue;
    const expect = Buffer.from(totpAt(secret, step));
    if (timingSafeEqual(expect, Buffer.from(clean))) return step;
  }
  return null;
}
/** What an authenticator app reads: issuer and account label make the entry recognisable in the app. */
export function otpauthUri(secret: string, email: string): string {
  const issuer = "Meesam";
  return `otpauth://totp/${encodeURIComponent(`${issuer}:${email}`)}?secret=${secret}&issuer=${issuer}&algorithm=SHA1&digits=6&period=${STEP}`;
}
export const newEmailCode = () => String(randomInt(0, 1_000_000)).padStart(6, "0");
const codeHash = (token: string, code: string) => sha256(`${token}:${code.replace(/\D/g, "")}`);

// ---- sign-in ------------------------------------------------------------------------------------
export async function twoFactorState(userId: string): Promise<{ required: boolean; totp: boolean }> {
  const r = rows<{ required: boolean; totp: boolean }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_2fa_state(${userId}::uuid)`)))[0];
  return { required: Boolean(r?.required), totp: Boolean(r?.totp) };
}
/** Opens the challenge and leaves its token in a cookie only this browser sends (15 minutes). */
export async function beginChallenge(userId: string): Promise<string> {
  const { token, hash } = newToken();
  await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_2fa_begin(${userId}::uuid, ${hash})`));
  (await cookies()).set(CHALLENGE_COOKIE, token, { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax", path: "/", maxAge: 15 * 60 });
  return token;
}
export interface Challenge { token: string; user_id: string; email: string; name: string; locale: string; totp: boolean; code_sent_at: string | null; verification_status: string }
export async function currentChallenge(): Promise<Challenge | null> {
  const token = (await cookies()).get(CHALLENGE_COOKIE)?.value;
  if (!token) return null;
  const r = rows<Omit<Challenge, "token">>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_2fa_challenge(${sha256(token)})`)))[0];
  return r ? { ...r, token } : null;
}
/** Records a fresh e-mail code for the challenge; returns it to be mailed, or null when one was sent under a minute ago. */
export async function issueEmailCode(token: string): Promise<string | null> {
  const code = newEmailCode();
  const ok = rows<{ ok: boolean }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_2fa_email_code(${sha256(token)}, ${codeHash(token, code)}) AS ok`)))[0]?.ok;
  return ok ? code : null;
}
export async function checkEmailCode(token: string, code: string): Promise<string | null> {
  return rows<{ id: string | null }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_2fa_check_email(${sha256(token)}, ${codeHash(token, code)}) AS id`)))[0]?.id ?? null;
}
export async function checkTotpCode(token: string, code: string): Promise<string | null> {
  const s = rows<{ secret: string | null; last_step: string | number | null }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_2fa_totp_secret(${sha256(token)})`)))[0];
  const step = s?.secret ? matchTotp(s.secret, code, s.last_step === null || s.last_step === undefined ? null : Number(s.last_step)) : null;
  return rows<{ id: string | null }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_2fa_totp_result(${sha256(token)}, ${step}::bigint) AS id`)))[0]?.id ?? null;
}
export async function clearChallenge(): Promise<void> { (await cookies()).delete(CHALLENGE_COOKIE); }

// ---- set-up by the signed-in user ----------------------------------------------------------------
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
export async function myTwoFactor(s: Session): Promise<{ required: boolean; totp: boolean; optIn: boolean; pending: string | null }> {
  return withAccount(db(), ctx(s), async (tx) => {
    const st = rows<{ required: boolean; totp: boolean }>(await tx.execute(sql`SELECT * FROM core.fn_2fa_state(${s.userId}::uuid)`))[0];
    const u = rows<{ two_factor_opt_in: boolean }>(await tx.execute(sql`SELECT two_factor_opt_in FROM core.app_user WHERE id = ${s.userId}::uuid`))[0];
    const p = rows<{ p: string | null }>(await tx.execute(sql`SELECT core.fn_totp_pending() AS p`))[0];
    return { required: Boolean(st?.required), totp: Boolean(st?.totp), optIn: Boolean(u?.two_factor_opt_in), pending: p?.p ?? null };
  });
}
export const beginTotp = (s: Session, secret: string) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_totp_pending(${secret})`));
export async function confirmTotp(s: Session, code: string): Promise<boolean> {
  return withAccount(db(), ctx(s), async (tx) => {
    const p = rows<{ p: string | null }>(await tx.execute(sql`SELECT core.fn_totp_pending() AS p`))[0]?.p;
    const step = p ? matchTotp(p, code) : null;
    if (step === null) return false;
    return Boolean(rows<{ ok: boolean }>(await tx.execute(sql`SELECT core.sp_totp_confirm(${step}::bigint) AS ok`))[0]?.ok);
  });
}
export const removeTotp = (s: Session) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_totp_remove()`));
export const setOptIn = (s: Session, on: boolean) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_2fa_opt(${on})`));
