import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { EMAIL_RE, issueToken, localeOf, redirectTo, text, withinLimits } from "@/lib/auth";
import { requestMeta } from "@/lib/session";
import { sendInviteMail, sendResetMail } from "@/lib/mail";
import { bootstrapStaffAdmin, isListedAdmin } from "@/lib/staff";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const email = text(form, "email").toLowerCase();
  // at most 3 reset e-mails an hour to one address and 10 an hour from one network address; the answer is the same either way
  const meta = await requestMeta();
  if (EMAIL_RE.test(email) && (await withinLimits([[`forgot:email:${email}`, 3, 60], [meta.ip ? `forgot:ip:${meta.ip}` : null, 10, 60]]))) {
    const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT user_id, user_status, locale FROM core.fn_user_for_login(${email}::citext)`))) as unknown as Array<{ user_id: string; user_status: string; locale: string }>;
    const u = rows[0];
    if (u && u.user_status === "active") {
      const token = await issueToken(u.user_id, "password_reset", "1 hour");
      try { await sendResetMail(email, "", u.locale === "ar" ? "ar" : "en", token); } catch { /* logged */ }
    } else if (u && u.user_status === "invited" && isListedAdmin(email)) {
      // the first System Administrator whose invitation never arrived (the e-mail failed, or the link ran out): send it again
      const token = await issueToken(u.user_id, "invite", "7 days");
      try { await sendInviteMail(email, email.split("@")[0] ?? "", "en", token, "Meesam staff", "Meesam"); } catch { /* logged */ }
    } else if (!u) {
      // the first System Administrator of an environment: an address named in configuration, not yet a login
      const staffId = await bootstrapStaffAdmin(email);
      if (staffId) {
        const token = await issueToken(staffId, "invite", "7 days");
        try { await sendInviteMail(email, email.split("@")[0] ?? "", "en", token, "Meesam staff", "Meesam"); } catch { /* logged */ }
      }
    }
  }
  return redirectTo(req, `/${locale}/forgot-password`, { sent: "1" });
}
