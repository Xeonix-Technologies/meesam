import { localeOf, redirectTo, text } from "@/lib/auth";
import { hashPassword, MIN_PASSWORD_LENGTH } from "@/lib/password";
import { acceptInvite } from "@/lib/users";
import { createSession } from "@/lib/session";
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
  // Signs the new user in here, replacing any other login open in this browser (for example the
  // administrator who sent the invitation), so the person lands in their own session.
  try {
    await recordConsent(userId, "invitation", true);
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "auth.accept-invite.consent", message: (err as Error).message }));
  }
  await createSession(userId);
  return redirectTo(req, `/${locale}/dashboard`);
}
