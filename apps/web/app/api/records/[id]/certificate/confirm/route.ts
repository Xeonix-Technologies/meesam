import { isLocale, pickText, type Locale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { CORRECTION_FIELDS, confirmCertificate, correctCertificate, withdrawCorrection, type CorrectionField } from "@/lib/certificate";
import { getRecord } from "@/lib/records";
import { sendCorrectionMail } from "@/lib/mail";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * What the certificate says is confirmed with a tick, or one field of it is corrected (Founder rulings 28 Nov 2026;
 * migration 0113). The database decides who may and whether the certificate agrees; a correction that the
 * certificate or the publication does not bear out is held, and Meesam's administrators and the person who entered
 * it are told by e-mail.
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  if (!UUID.test(id)) return go(req, `/${locale}/records`);
  const back = `/${locale}/records/${id}`;
  const action = String(form.get("action") ?? "");
  try {
    if (action === "confirm") {
      if (form.get("confirm") !== "yes") return go(req, back, { error: "certTick" });
      await confirmCertificate(auth.session, id);
      return go(req, back, { saved: "certConfirmed" });
    }
    if (action === "withdraw") {
      const cid = String(form.get("correction_id") ?? "");
      if (UUID.test(cid)) await withdrawCorrection(auth.session, cid);
      return go(req, back, { saved: "certWithdrawn" });
    }
    if (action === "correct") {
      const field = String(form.get("field") ?? "") as CorrectionField;
      const value = String(form.get("value") ?? "").trim().slice(0, 300);
      if (!CORRECTION_FIELDS.includes(field) || !value) return go(req, back, { error: "certCorrection" });
      const out = await correctCertificate(auth.session, id, field, value);
      if (out.state === "accepted") return go(req, back, { saved: "certCorrected" });
      const r = await getRecord(auth.session, id);
      const mark = r ? pickText(r.mark_text, locale) || r.registration_no || r.application_no || "" : "";
      await Promise.allSettled(out.alert.map((a) => sendCorrectionMail(a.email, a.name, (isLocale(a.locale) ? a.locale : "en") as Locale, a.staff ? "heldStaff" : "held",
        { mark, field, value, note: "", path: a.staff ? "admin/certificates" : `records/${id}` })));
      return go(req, back, { error: "certHeld" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    const code = err.cause?.code;
    console.error(JSON.stringify({ level: "error", at: "certificate.confirm", action, record: id, code: code ?? null, message: err.cause?.message ?? err.message }));
    // 42501: a Viewer or not this account's record; 55000: the certificate does not agree yet, or a correction of this field is open; 22023: not a value for this field
    return go(req, back, { error: code === "42501" ? "notAllowed" : code === "55000" ? "certNotYet" : code === "22023" ? "certCorrection" : "generic" });
  }
  return go(req, back);
}
