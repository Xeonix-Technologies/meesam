import { isLocale } from "@meesam/i18n";
import { redirectTo } from "@/lib/auth";
import { afterLogin } from "@/lib/afterLogin";
import { createSession } from "@/lib/session";
import { sendLoginCodeMail } from "@/lib/mail";
import { checkEmailCode, checkTotpCode, clearChallenge, currentChallenge, issueEmailCode } from "@/lib/twofactor";

export const runtime = "nodejs";

/**
 * Second step of sign-in: checks the authenticator or e-mail code for the open challenge and only then opens
 * the session. "send" mails a fresh code (also the fallback for someone without their authenticator app).
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const back = `/${locale}/login/verify`;
  const ch = await currentChallenge();
  if (!ch) { await clearChallenge(); return redirectTo(req, `/${locale}/login`, { error: "expired" }); }
  const action = String(form.get("action") ?? "verify");
  if (action === "cancel") { await clearChallenge(); return redirectTo(req, `/${locale}/login`); }
  if (action === "send") {
    const code = await issueEmailCode(ch.token);
    if (!code) return redirectTo(req, back, { method: "email", error: "wait" });
    try { await sendLoginCodeMail(ch.email, ch.locale === "ar" ? "ar" : "en", code); }
    catch (e) { console.error(JSON.stringify({ level: "error", at: "2fa.mail", message: (e as Error).message })); return redirectTo(req, back, { method: "email", error: "mail" }); }
    return redirectTo(req, back, { method: "email", sent: "1" });
  }
  const method = form.get("method") === "email" ? "email" : "totp";
  const code = String(form.get("code") ?? "").replace(/\D/g, "").slice(0, 6);
  const userId = code.length === 6 ? (method === "email" ? await checkEmailCode(ch.token, code) : await checkTotpCode(ch.token, code)) : null;
  if (!userId) {
    // the challenge closes itself after six wrong tries; then the password is asked again
    if (!(await currentChallenge())) { await clearChallenge(); return redirectTo(req, `/${locale}/login`, { error: "expired" }); }
    return redirectTo(req, back, { method, error: "code" });
  }
  await clearChallenge();
  await createSession(userId);
  return afterLogin(req, { userId, email: ch.email, locale: ch.locale, verification_status: ch.verification_status });
}
