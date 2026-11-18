import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { EMAIL_RE, issueToken } from "@/lib/auth";
import { getSession } from "@/lib/session";
import { inviteStaff, removeStaff, staffRoles, STAFF_ROLES, type StaffRole } from "@/lib/staff";
import { sendInviteMail } from "@/lib/mail";

export const runtime = "nodejs";

/**
 * System Admin → Staff: invite a person to a separate staff login, send the invitation again, or remove one
 * (Founder ruling 18 Nov 2026: staff never use the login of an owner or agency account). System administrators only.
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("system_admin")) return new NextResponse(null, { status: 404 });
  const back = `/${locale}/admin/staff`;
  const action = String(form.get("action") ?? "");
  const userId = String(form.get("user_id") ?? "");
  const invite = async (id: string, email: string, name: string) => {
    const token = await issueToken(id, "invite", "7 days");
    await sendInviteMail(email, name, "en", token, "Meesam staff", session.userName);
  };
  try {
    if (action === "invite") {
      const email = String(form.get("email") ?? "").trim().toLowerCase().slice(0, 200);
      const name = String(form.get("name") ?? "").trim().slice(0, 120);
      const role = String(form.get("role") ?? "") as StaffRole;
      if (!name) return go(req, back, { error: "required" });
      if (!EMAIL_RE.test(email)) return go(req, back, { error: "email" });
      if (!STAFF_ROLES.includes(role)) return go(req, back, { error: "generic" });
      const id = await inviteStaff(session, email, name, role);
      try { await invite(id, email, name); } catch { return go(req, back, { error: "mail" }); }
      return go(req, back, { saved: "invited" });
    }
    if (!/^[0-9a-f-]{36}$/.test(userId)) return go(req, back, { error: "generic" });
    if (action === "resend") {
      const email = String(form.get("email") ?? "").trim().toLowerCase(), name = String(form.get("name") ?? "").trim();
      try { await invite(userId, email, name); } catch { return go(req, back, { error: "mail" }); }
      return go(req, back, { saved: "invited" });
    }
    if (action === "remove") {
      if (userId === session.userId) return go(req, back, { error: "self" });
      await removeStaff(userId);
      return go(req, back, { saved: "removed" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    const msg = err.cause?.message ?? err.message;
    if (err.cause?.code === "23505" || /already registered/.test(msg)) return go(req, back, { error: "emailTaken" });
    if (/last active System Administrator/.test(msg)) return go(req, back, { error: "lastAdmin" });
    console.error(JSON.stringify({ level: "error", at: "admin.staff", action, message: err.message, cause: msg }));
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { error: "generic" });
}
