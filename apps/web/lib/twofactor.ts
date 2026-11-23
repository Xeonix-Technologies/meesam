import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
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

/**
 * The authenticator secret is sealed before it is stored (Founder ruling R13, 21 Nov 2026): AES-256-GCM under a key
 * of its own, TWO_FACTOR_KEY, kept apart from the database and from every other secret. A copy of the database
 * alone therefore does not give anyone the means to produce sign-in codes. Stored form: v1.<iv>.<text>.<tag>.
 * Secrets stored before the key existed are plain; each is sealed the next time its owner signs in with a code.
 * Losing or changing the key locks every authenticator out (users then set one up again), so it is set once and sealed.
 */
const sealKey = (): Buffer | null => {
  const k = process.env.TWO_FACTOR_KEY;
  return k && k.length >= 32 ? createHash("sha256").update(k).digest() : null;
};
export const isSealed = (stored: string) => stored.startsWith("v1.");
export function sealSecret(secret: string): string {
  const key = sealKey();
  if (!key) return secret;
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", key, iv);
  const text = Buffer.concat([c.update(secret, "utf8"), c.final()]);
  return `v1.${iv.toString("base64url")}.${text.toString("base64url")}.${c.getAuthTag().toString("base64url")}`;
}
/** The secret as the authenticator knows it; null when it is sealed and cannot be opened with the key in place. */
export function openSecret(stored: string | null | undefined): string | null {
  if (!stored) return null;
  if (!isSealed(stored)) return stored;
  const key = sealKey();
  const [, iv, text, tag] = stored.split(".");
  if (!key || !iv || !text || !tag) { console.error(JSON.stringify({ level: "error", at: "2fa.seal", message: "a sealed authenticator secret cannot be opened: TWO_FACTOR_KEY is missing or the value is malformed" })); return null; }
  try {
    const d = createDecipheriv("aes-256-gcm", key, Buffer.from(iv, "base64url"));
    d.setAuthTag(Buffer.from(tag, "base64url"));
    return Buffer.concat([d.update(Buffer.from(text, "base64url")), d.final()]).toString("utf8");
  } catch {
    console.error(JSON.stringify({ level: "error", at: "2fa.seal", message: "a sealed authenticator secret did not open with TWO_FACTOR_KEY (was the key changed?)" }));
    return null;
  }
}

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
  const secret = openSecret(s?.secret);
  const step = secret ? matchTotp(secret, code, s?.last_step === null || s?.last_step === undefined ? null : Number(s.last_step)) : null;
  // a secret stored before the key existed is sealed now, while the sign-in that proves it is in hand (ruling R13)
  if (step !== null && secret && s?.secret && !isSealed(s.secret) && sealKey()) {
    await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_2fa_totp_seal(${sha256(token)}, ${s.secret}, ${sealSecret(secret)})`)).catch((e) => console.error(JSON.stringify({ level: "error", at: "2fa.seal", message: (e as Error).message })));
  }
  return rows<{ id: string | null }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_2fa_totp_result(${sha256(token)}, ${step}::bigint) AS id`)))[0]?.id ?? null;
}
/** Whether this login is still to be asked, once, whether and how to use two-step sign-in (migration 0084). */
export async function askTwoStep(userId: string): Promise<boolean> {
  return Boolean(rows<{ ask: boolean }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.fn_2fa_ask(${userId}::uuid) AS ask`)))[0]?.ask);
}
export async function clearChallenge(): Promise<void> { (await cookies()).delete(CHALLENGE_COOKIE); }

// ---- set-up by the signed-in user ----------------------------------------------------------------
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
export async function myTwoFactor(s: Session): Promise<{ required: boolean; totp: boolean; optIn: boolean; pending: string | null }> {
  return withAccount(db(), ctx(s), async (tx) => {
    const st = rows<{ required: boolean; totp: boolean }>(await tx.execute(sql`SELECT * FROM core.fn_2fa_state(${s.userId}::uuid)`))[0];
    const u = rows<{ two_factor_opt_in: boolean }>(await tx.execute(sql`SELECT two_factor_opt_in FROM core.app_user WHERE id = ${s.userId}::uuid`))[0];
    const p = rows<{ p: string | null }>(await tx.execute(sql`SELECT core.fn_totp_pending() AS p`))[0];
    return { required: Boolean(st?.required), totp: Boolean(st?.totp), optIn: Boolean(u?.two_factor_opt_in), pending: openSecret(p?.p) };
  });
}
export const beginTotp = (s: Session, secret: string) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_totp_pending(${sealSecret(secret)})`));
export async function confirmTotp(s: Session, code: string): Promise<boolean> {
  return withAccount(db(), ctx(s), async (tx) => {
    const p = openSecret(rows<{ p: string | null }>(await tx.execute(sql`SELECT core.fn_totp_pending() AS p`))[0]?.p);
    const step = p ? matchTotp(p, code) : null;
    if (step === null) return false;
    return Boolean(rows<{ ok: boolean }>(await tx.execute(sql`SELECT core.sp_totp_confirm(${step}::bigint) AS ok`))[0]?.ok);
  });
}
export const removeTotp = (s: Session) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_totp_remove()`));
export const markAsked = (s: Session) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_2fa_asked()`));
export const setOptIn = (s: Session, on: boolean) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.sp_2fa_opt(${on})`));
