import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { numberProblem, recordNumbers, updateCertificate, setPriorityClaimed } from "@/lib/records";
import { fillFromCertificate } from "@/lib/certificate";

export const runtime = "nodejs";
// a two-digit year typed into a date field arrives as 00yy; read it as 20yy
const date = (v: FormDataEntryValue | null) => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? (Number(v.slice(0, 4)) < 100 ? `20${v.slice(2)}` : v) : null);
const text = (v: FormDataEntryValue | null) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 60) : null);

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const numbers = { application_no: text(form.get("application_no")), registration_no: text(form.get("registration_no")) };
  const before = await recordNumbers(auth.session, id);
  try {
    await updateCertificate(auth.session, id, { ...numbers, filing_date: date(form.get("filing_date")), registration_date: date(form.get("registration_date")), expiry_date: date(form.get("expiry_date")) });
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string; constraint_name?: string; constraint?: string } };
    console.error(JSON.stringify({ level: "error", at: "record.certificate", record: id, code: err.cause?.code ?? null, message: err.cause?.message ?? err.message }));
    // 23505: the number is on an active trademark of another holder, or already in this account (migration 0111). Nothing was saved.
    return go(req, back, { tab: "certificate", error: numberProblem(e) ?? (err.cause?.code === "23505" ? "numberTaken" : err.cause?.code === "42501" ? "notAllowed" : "generic") });
  }
  await setPriorityClaimed(auth.session, id, form.get("priority_claimed") === "1");
  // the number was corrected: if it is now the certificate's, the dates are taken from the certificate (Founder, 28 Nov 2026)
  const changed = before && ((numbers.application_no ?? before.application_no) !== before.application_no || (numbers.registration_no ?? before.registration_no) !== before.registration_no);
  const filled = changed ? await fillFromCertificate(auth.session, id) : false;
  return go(req, back, { tab: "certificate", saved: filled ? "fromCertificate" : "1" });
}
