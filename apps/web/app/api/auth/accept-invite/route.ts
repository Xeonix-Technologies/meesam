import { localeOf, redirectTo, text } from "@/lib/auth";
import { hashPassword, MIN_PASSWORD_LENGTH } from "@/lib/password";
import { acceptInvite } from "@/lib/users";
import { recordConsent } from "@/lib/consent";

export const runtime = "nodejs";

/** The invited person chooses a password; the invitation token is used once and the user becomes active. */
export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const token = text(form, "token", 200);
  const password = String(form.get("password") ?? "");
  const password2 = String(form.get("password2") ?? "");
  const back = `/${locale}/accept-invite`;
  if (password.length < MIN_PASSWORD_LENGTH) return redirectTo(req, back, { token, error: "password" });
  if (password !== password2) return redirectTo(req, back, { token, error: "passwordMatch" });
  if (text(form, "consent") !== "1") return redirectTo(req, back, { token, error: "consent" });
  const userId = await acceptInvite(token, await hashPassword(password));
  if (!userId) return redirectTo(req, back, { error: "bad" });
  try {
    await recordConsent(userId, "invitation", true);
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "auth.accept-invite.consent", message: (err as Error).message }));
  }
  // Founder ruling 23 Nov 2026: setting a password from an invitation does not sign the person in. They sign in on
  // the log-in page like everyone else, so a second step that applies to them is asked from the first entry.
  return redirectTo(req, `/${locale}/login`, { reset: "1" });
}
