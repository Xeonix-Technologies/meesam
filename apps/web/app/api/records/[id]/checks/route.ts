import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { text } from "@/lib/auth";
import { confirmWarning } from "@/lib/records";

export const runtime = "nodejs";

/** Confirms an advisory check as correct (item 4.7 step 7): the warning stays with the record, marked confirmed with the note. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const code = text(form, "code", 60), field = text(form, "field", 60), note = text(form, "note", 300);
  if (!code || !field) return go(req, `/${locale}/records/${id}`, { error: "generic" });
  await confirmWarning(auth.session, id, code, field, note);
  return go(req, `/${locale}/records/${id}`, { saved: "1" });
}
