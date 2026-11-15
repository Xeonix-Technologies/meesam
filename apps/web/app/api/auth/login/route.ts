import { EMAIL_RE, localeOf, recentFailures, recordAttempt, redirectTo, text, userForLogin } from "@/lib/auth";
import { verifyPassword } from "@/lib/password";
import { createSession, requestMeta } from "@/lib/session";

export const runtime = "nodejs";
const MAX_FAILURES = 8;

export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const back = `/${locale}/login`;
  const email = text(form, "email").toLowerCase();
  const password = String(form.get("password") ?? "");
  if (!EMAIL_RE.test(email) || !password) return redirectTo(req, back, { error: "invalid" });

  const meta = await requestMeta();
  if ((await recentFailures(email)) >= MAX_FAILURES) return redirectTo(req, back, { error: "throttled" });

  const row = await userForLogin(email);
  const ok = row !== null && row.user_status !== "suspended" && row.user_status !== "removed" && (await verifyPassword(password, row.password_hash));
  await recordAttempt(email, ok, meta.ip, meta.userAgent);
  if (!ok || !row) return redirectTo(req, back, { error: "invalid" });
  if (row.user_status === "invited") return redirectTo(req, back, { error: "unverifiedEmail", email });

  await createSession(row.user_id);
  const target = row.verification_status === "verified" ? "dashboard" : "verification";
  return redirectTo(req, `/${row.locale === "ar" ? "ar" : "en"}/${target}`);
}
