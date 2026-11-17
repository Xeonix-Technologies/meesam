import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { text } from "@/lib/auth";
import { updateUserProfile } from "@/lib/account";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale, { ownDetails: true });
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  const name = text(form, "user_name", 120);
  const pref = text(form, "user_locale", 5);
  if (!name) return go(req, back, { error: "required", field: "user_name" });
  await updateUserProfile(auth.session, { name, locale: isLocale(pref) ? pref : auth.session.locale });
  return go(req, back, { saved: "user" });
}
