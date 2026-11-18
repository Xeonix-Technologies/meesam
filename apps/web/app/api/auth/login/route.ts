import { EMAIL_RE, localeOf, recentFailures, recordAttempt, redirectTo, text, userForLogin } from "@/lib/auth";
import { verifyPassword } from "@/lib/password";
import { cookies } from "next/headers";
import { createSession, requestMeta } from "@/lib/session";
import { passPreview } from "@/lib/pass";

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
  // an owner pass opened before logging in is waiting: go back to it (item 39 (vii)); a code no longer valid is dropped
  const jar = await cookies();
  const held = jar.get("ms_pass_hold")?.value;
  if (held) {
    if (await passPreview(held).catch(() => null)) return redirectTo(req, `/${row.locale === "ar" ? "ar" : "en"}/pass`, { code: held });
    jar.delete("ms_pass_hold");
  }
  const target = row.verification_status === "verified" ? "dashboard" : "verification";
  return redirectTo(req, `/${row.locale === "ar" ? "ar" : "en"}/${target}`);
}
