import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { updateCertificate } from "@/lib/records";

export const runtime = "nodejs";
const date = (v: FormDataEntryValue | null) => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);
const text = (v: FormDataEntryValue | null) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 60) : null);

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  await updateCertificate(auth.session, id, {
    application_no: text(form.get("application_no")), filing_date: date(form.get("filing_date")),
    registration_no: text(form.get("registration_no")), registration_date: date(form.get("registration_date")), expiry_date: date(form.get("expiry_date")),
  });
  return go(req, `/${locale}/records/${id}`, { tab: "certificate", saved: "1" });
}
