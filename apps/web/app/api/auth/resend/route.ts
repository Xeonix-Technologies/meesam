import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { EMAIL_RE, issueToken, localeOf, redirectTo, text, withinLimits } from "@/lib/auth";
import { requestMeta } from "@/lib/session";
import { sendVerifyMail } from "@/lib/mail";

export const runtime = "nodejs";

/** Sends the e-mail confirmation link again. Always answers the same way (no account enumeration). */
export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const email = text(form, "email").toLowerCase();
  // at most 3 confirmation e-mails an hour to one address and 10 an hour from one network address; the answer is the same either way
  const meta = await requestMeta();
  if (EMAIL_RE.test(email) && (await withinLimits([[`resend:email:${email}`, 3, 60], [meta.ip ? `resend:ip:${meta.ip}` : null, 10, 60]]))) {
    const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT user_id, user_status FROM core.fn_user_for_login(${email}::citext)`))) as unknown as Array<{ user_id: string; user_status: string }>;
    const u = rows[0];
    if (u && u.user_status === "invited") {
      const token = await issueToken(u.user_id, "email_verify", "24 hours");
      try { await sendVerifyMail(email, "", locale, token); } catch { /* logged in sendMail */ }
    }
  }
  return redirectTo(req, `/${locale}/check-email`, { email, resent: "1" });
}
