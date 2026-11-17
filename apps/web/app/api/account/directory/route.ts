import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { setDirectoryListed } from "@/lib/appointments";

export const runtime = "nodejs";

/** An agency office chooses whether owners can find it in Meesam's directory (administrators only). */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  if (auth.session.accountKind !== "agency_office" || auth.session.role !== "agency_admin") return go(req, back, { error: "adminOnly" });
  await setDirectoryListed(auth.session, form.get("listed") === "yes");
  return go(req, back, { saved: "directory" });
}
