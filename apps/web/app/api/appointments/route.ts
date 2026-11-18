import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { pickText } from "@meesam/i18n";
import { appointmentRecipients, endAppointment, requestAppointment, respondAppointment, setAppointmentRecords } from "@/lib/appointments";
import { sendAppointmentMail } from "@/lib/mail";
import type { Session } from "@/lib/session";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** E-mails the other side's users; a mail failure never undoes the action (the in-app notice is already written). */
async function tell(s: Session, id: string, kind: "requested" | "accepted" | "declined" | "ended" | "scope", note = ""): Promise<void> {
  try {
    const to = await appointmentRecipients(s, id);
    // the recipient is the other side: an owner's users open Agencies, an agency's users open Clients
    const path = s.accountKind === "agency_office" ? "agencies" : "clients";
    await Promise.allSettled(to.map((u) => { const l = u.locale === "ar" ? "ar" : "en"; return sendAppointmentMail(u.email, u.name, l, kind, pickText(s.accountName, l), path, note); }));
  } catch (e) { console.error(JSON.stringify({ level: "error", at: "appointments.mail", kind, message: (e as Error).message })); }
}

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
      const newId = await requestAppointment(auth.session, other, records, text("message", 1000));
      await tell(auth.session, newId, "requested", text("message", 1000));
      return go(req, back, { saved: "requested" });
    }
    if ((action === "accept" || action === "decline") && UUID.test(id)) {
      if (action === "accept" && auth.session.accountKind !== "agency_office" && records.length === 0) return go(req, back, { error: "noRecords" });
      await respondAppointment(auth.session, id, action === "accept", records, text("note", 500));
      await tell(auth.session, id, action === "accept" ? "accepted" : "declined", text("note", 500));
      return go(req, back, { saved: action === "accept" ? "accepted" : "declined" });
    }
    if (action === "end" && UUID.test(id)) { await endAppointment(auth.session, id); await tell(auth.session, id, "ended"); return go(req, back, { saved: "ended" }); }
    if (action === "scope" && UUID.test(id)) {
      if (records.length === 0) return go(req, back, { error: "noRecordsEnd" });
      await setAppointmentRecords(auth.session, id, records);
      await tell(auth.session, id, "scope");
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
