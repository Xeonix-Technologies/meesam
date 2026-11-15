import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { EMAIL_RE, issueToken, localeOf, redirectTo, text } from "@/lib/auth";
import { sendVerifyMail } from "@/lib/mail";

export const runtime = "nodejs";

/** Sends the e-mail confirmation link again. Always answers the same way (no account enumeration). */
export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const email = text(form, "email").toLowerCase();
  if (EMAIL_RE.test(email)) {
    const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT user_id, user_status FROM core.fn_user_for_login(${email}::citext)`))) as unknown as Array<{ user_id: string; user_status: string }>;
    const u = rows[0];
    if (u && u.user_status === "invited") {
      const token = await issueToken(u.user_id, "email_verify", "24 hours");
      try { await sendVerifyMail(email, "", locale, token); } catch { /* logged in sendMail */ }
    }
  }
  return redirectTo(req, `/${locale}/check-email`, { email, resent: "1" });
}
