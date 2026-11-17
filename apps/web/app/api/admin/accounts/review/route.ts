import { NextResponse } from "next/server";
import { isLocale, type Locale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { reviewAccount, staffRoles } from "@/lib/staff";
import { sendReviewMail } from "@/lib/mail";

export const runtime = "nodejs";

/** System Admin: approve or reject an account's verification. System administrators only. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("system_admin")) return new NextResponse(null, { status: 404 });
  const back = `/${locale}/admin`;
  const accountId = String(form.get("account_id") ?? "");
  const decision = String(form.get("decision") ?? "");
  const note = String(form.get("note") ?? "").trim().slice(0, 300);
  if (!/^[0-9a-f-]{36}$/.test(accountId) || !["approve", "reject"].includes(decision)) return go(req, back, { error: "generic" });
  if (decision === "reject" && !note) return go(req, back, { error: "noteRequired" });
  try {
    const users = await reviewAccount(session, accountId, decision === "approve", note);
    for (const u of users) {
      try { await sendReviewMail(u.email, u.name, (isLocale(u.locale) ? u.locale : "en") as Locale, decision === "approve", note); }
      catch (e) { console.error(JSON.stringify({ level: "error", at: "admin.review.mail", message: (e as Error).message })); }
    }
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "admin.review", message: (e as Error).message }));
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { saved: decision === "approve" ? "approved" : "rejected" });
}
