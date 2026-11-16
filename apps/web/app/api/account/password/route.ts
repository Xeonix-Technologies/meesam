import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { changePassword } from "@/lib/account";
import { MIN_PASSWORD_LENGTH } from "@/lib/password";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  const current = String(form.get("current_password") ?? "");
  const next = String(form.get("new_password") ?? "");
  const confirm = String(form.get("confirm_password") ?? "");
  if (next.length < MIN_PASSWORD_LENGTH) return go(req, back, { error: "passwordShort", field: "new_password" });
  if (next !== confirm) return go(req, back, { error: "passwordMismatch", field: "confirm_password" });
  const result = await changePassword(auth.session, current, next);
  if (result === "wrong_current") return go(req, back, { error: "wrongCurrent", field: "current_password" });
  return go(req, back, { saved: "password" });
}
