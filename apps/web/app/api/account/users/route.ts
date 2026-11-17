import { isLocale, pickText } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { EMAIL_RE, issueToken, text } from "@/lib/auth";
import { sendInviteMail } from "@/lib/mail";
import { inviteUser, isAccountAdmin, openInvitation, rolesFor, setUserRole, setUserStatus, type UserRole } from "@/lib/users";
import type { Session } from "@/lib/session";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const INVITE_TTL = "7 days";

async function sendInvitation(s: Session, u: { id: string; email: string; name: string; locale: string }): Promise<boolean> {
  const token = await issueToken(u.id, "invite", INVITE_TTL);
  const locale = u.locale === "ar" ? "ar" : "en";
  try { await sendInviteMail(u.email, u.name, locale, token, pickText(s.accountName, locale), s.userName); return true; } catch { return false; }
}

/** Users of the account: invite, change role, suspend, reactivate, remove. The database functions check the caller (migration 0011). */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const s = auth.session;
  const back = `/${locale}/users`;
  if (!isAccountAdmin(s) || s.accountKind === "owner_individual") return go(req, `/${locale}/dashboard`);
  const action = text(form, "action", 20);
  const id = text(form, "user_id", 40);
  const roles = rolesFor(s.accountKind);
  try {
    if (action === "invite") {
      const email = text(form, "email").toLowerCase();
      const name = text(form, "name", 120);
      const role = text(form, "role", 20) as UserRole;
      const pref = text(form, "user_locale", 5);
      if (!name) return go(req, back, { error: "required", field: "name" });
      if (!EMAIL_RE.test(email)) return go(req, back, { error: "email", field: "email" });
      if (!roles.includes(role)) return go(req, back, { error: "generic" });
      const userId = await inviteUser(s, { email, name, role, locale: isLocale(pref) ? pref : locale });
      const sent = await sendInvitation(s, { id: userId, email, name, locale: isLocale(pref) ? pref : locale });
      return go(req, back, sent ? { saved: "invited" } : { error: "mail" });
    }
    if (!UUID.test(id)) return go(req, back, { error: "generic" });
    if (action === "resend") {
      const u = await openInvitation(s, id);
      if (!u) return go(req, back, { error: "generic" });
      return go(req, back, (await sendInvitation(s, u)) ? { saved: "invited" } : { error: "mail" });
    }
    if (action === "role") {
      const role = text(form, "role", 20) as UserRole;
      if (!roles.includes(role)) return go(req, back, { error: "generic" });
      await setUserRole(s, id, role);
      return go(req, back, { saved: "role" });
    }
    if (action === "suspend" || action === "activate" || action === "remove") {
      await setUserStatus(s, id, action === "suspend" ? "suspended" : action === "activate" ? "active" : "removed");
      return go(req, back, { saved: action === "suspend" ? "suspended" : action === "activate" ? "activated" : "removed" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    const code = err.cause?.code;
    const msg = err.cause?.message ?? err.message;
    if (code === "23505" || /already registered/.test(msg)) return go(req, back, { error: "emailTaken", field: "email" });
    if (/one active administrator/.test(msg)) return go(req, back, { error: "lastAdmin" });
    if (/their own login/.test(msg)) return go(req, back, { error: "self" });
    console.error(JSON.stringify({ level: "error", at: "account.users", action, message: err.message, cause: msg, code }));
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { error: "generic" });
}
