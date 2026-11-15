import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { EMAIL_RE, issueToken, localeOf, redirectTo, text } from "@/lib/auth";
import { sendResetMail } from "@/lib/mail";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const email = text(form, "email").toLowerCase();
  if (EMAIL_RE.test(email)) {
    const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT user_id, user_status, locale FROM core.fn_user_for_login(${email}::citext)`))) as unknown as Array<{ user_id: string; user_status: string; locale: string }>;
    const u = rows[0];
    if (u && u.user_status === "active") {
      const token = await issueToken(u.user_id, "password_reset", "1 hour");
      try { await sendResetMail(email, "", u.locale === "ar" ? "ar" : "en", token); } catch { /* logged */ }
    }
  }
  return redirectTo(req, `/${locale}/forgot-password`, { sent: "1" });
}
