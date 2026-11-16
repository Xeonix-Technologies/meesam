import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { text } from "@/lib/auth";
import { updateAccountProfile } from "@/lib/account";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  const ar = text(form, "name_ar"), en = text(form, "name_en");
  const country = text(form, "country", 2).toUpperCase();
  if (!ar && !en) return go(req, back, { error: "required", field: "name_en" });
  if (!/^[A-Z]{2}$/.test(country)) return go(req, back, { error: "required", field: "country" });
  const name: Record<string, string> = {};
  if (ar) name.ar = ar;
  if (en) name.en = en;
  const contact: Record<string, string> = {};
  for (const k of ["mobile", "phone", "website", "address"]) { const v = text(form, k, k === "address" ? 300 : 120); if (v) contact[k] = v; }
  try {
    await updateAccountProfile(auth.session, { name, country, city: text(form, "city", 80) || null, contact });
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "account.profile", message: (e as Error).message }));
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { saved: "profile" });
}
