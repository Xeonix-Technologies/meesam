import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { endAppointment, requestAppointment, respondAppointment, setAppointmentRecords } from "@/lib/appointments";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** One entry point for the appointment actions; the database functions decide who may do what (migration 0010). */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/${auth.session.accountKind === "agency_office" ? "clients" : "agencies"}`;
  const action = String(form.get("action") ?? "");
  const id = String(form.get("appointment_id") ?? "");
  const other = String(form.get("account_id") ?? "");
  const records = form.getAll("record_id").map(String).filter((x) => UUID.test(x));
  const text = (k: string, n: number) => String(form.get(k) ?? "").trim().slice(0, n);
  try {
    if (action === "request" && UUID.test(other)) {
      if (auth.session.accountKind !== "agency_office" && records.length === 0) return go(req, back, { error: "noRecords" });
      await requestAppointment(auth.session, other, records, text("message", 1000));
      return go(req, back, { saved: "requested" });
    }
    if ((action === "accept" || action === "decline") && UUID.test(id)) {
      if (action === "accept" && auth.session.accountKind !== "agency_office" && records.length === 0) return go(req, back, { error: "noRecords" });
      await respondAppointment(auth.session, id, action === "accept", records, text("note", 500));
      return go(req, back, { saved: action === "accept" ? "accepted" : "declined" });
    }
    if (action === "end" && UUID.test(id)) { await endAppointment(auth.session, id); return go(req, back, { saved: "ended" }); }
    if (action === "scope" && UUID.test(id)) {
      if (records.length === 0) return go(req, back, { error: "noRecordsEnd" });
      await setAppointmentRecords(auth.session, id, records);
      return go(req, back, { saved: "scope" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string; constraint_name?: string } };
    console.error(JSON.stringify({ level: "error", at: "appointments", action, message: err.message, cause: err.cause?.message, code: err.cause?.code }));
    if (err.cause?.constraint_name === "appointment_one_open" || /appointment_one_open/.test(err.cause?.message ?? err.message)) return go(req, back, { error: "alreadyOpen" });
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { error: "generic" });
}
