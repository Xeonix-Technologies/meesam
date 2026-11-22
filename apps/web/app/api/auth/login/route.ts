import { EMAIL_RE, localeOf, recentFailures, recentFailuresFromIp, recordAttempt, redirectTo, text, userForLogin } from "@/lib/auth";
import { verifyPassword } from "@/lib/password";
import { createSession, requestMeta } from "@/lib/session";
import { afterLogin } from "@/lib/afterLogin";
import { beginChallenge, clearChallenge, issueEmailCode, twoFactorState } from "@/lib/twofactor";
import { sendLoginCodeMail } from "@/lib/mail";

export const runtime = "nodejs";
const MAX_FAILURES = 8;
// one network address trying many e-mail addresses (sign-in limits review, 21 Nov 2026); offices share an address, so this is higher
const MAX_FAILURES_PER_ADDRESS = 40;

export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const back = `/${locale}/login`;
  const email = text(form, "email").toLowerCase();
  const password = String(form.get("password") ?? "");
  if (!EMAIL_RE.test(email) || !password) return redirectTo(req, back, { error: "invalid" });

  const meta = await requestMeta();
  if ((await recentFailures(email)) >= MAX_FAILURES || (await recentFailuresFromIp(meta.ip)) >= MAX_FAILURES_PER_ADDRESS) return redirectTo(req, back, { error: "throttled" });

  const row = await userForLogin(email);
  const ok = row !== null && row.user_status !== "suspended" && row.user_status !== "removed" && (await verifyPassword(password, row.password_hash));
  await recordAttempt(email, ok, meta.ip, meta.userAgent);
  if (!ok || !row) {
    // a second step left open by an earlier, correct attempt must not be reachable after a wrong password
    await clearChallenge();
    return redirectTo(req, back, { error: "invalid" });
  }
  if (row.user_status === "invited") return redirectTo(req, back, { error: "unverifiedEmail", email });

  // Two-factor sign-in (Founder ruling 18 Nov 2026): staff and account administrators, and anyone who switched it
  // on, give a second factor before a session is opened. Without an authenticator app the code goes by e-mail.
  const second = await twoFactorState(row.user_id);
  if (second.required) {
    const token = await beginChallenge(row.user_id);
    if (!second.totp) {
      const code = await issueEmailCode(token);
      if (code) await sendLoginCodeMail(email, row.locale === "ar" ? "ar" : "en", code).catch((e) => console.error(JSON.stringify({ level: "error", at: "login.2fa.mail", message: (e as Error).message })));
    }
    return redirectTo(req, `/${row.locale === "ar" ? "ar" : "en"}/login/verify`);
  }

  await createSession(row.user_id);
  return afterLogin(req, { email, locale: row.locale, verification_status: row.verification_status });
}
