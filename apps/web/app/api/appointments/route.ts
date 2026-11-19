import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { pickText } from "@meesam/i18n";
import { appointmentRecipients, endAppointment, inviteOwner, requestAppointment, respondAppointment, setAppointmentRecords, withdrawOwnerInvite } from "@/lib/appointments";
import { sendAppointmentMail, sendOwnerInviteMail } from "@/lib/mail";
import { flushStaffNotices } from "@/lib/staff";
import { listPortfolio } from "@/lib/records";
import type { Session } from "@/lib/session";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** E-mails the other side's users; a mail failure never undoes the action (the in-app notice is already written). */
async function tell(s: Session, id: string, kind: "requested" | "accepted" | "declined" | "ended" | "scope", note = ""): Promise<void> {
  try {
    const to = await appointmentRecipients(s, id);
    // the recipient is the other side: an owner's users open Agencies, an agency's users open Clients
    const path = s.accountKind === "agency_office" ? "agencies" : "clients";
    await Promise.allSettled(to.map((u) => { const l = u.locale === "ar" ? "ar" : "en"; return sendAppointmentMail(u.email, u.name, l, kind, pickText(s.accountName, l), path, note, u.account_id); }));
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
    // Founder ruling 18 Nov 2026 (10): the agency enters the owner's e-mail; an existing owner gets a request, a new one a sign-up link
    if (action === "invite_owner" && auth.session.accountKind === "agency_office") {
      const email = text("email", 254).toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return go(req, back, { error: "email" });
      const r = await inviteOwner(auth.session, email, text("message", 1000));
      await flushStaffNotices();   // an owner waiting for review is verified by the invitation (0028)
      if (r.outcome === "request" && r.appointment_id) { await tell(auth.session, r.appointment_id, "requested", text("message", 1000)); return go(req, back, { saved: "requested" }); }
      try { await sendOwnerInviteMail(email, locale, pickText(auth.session.accountName, locale), text("message", 1000)); }
      catch (e) { console.error(JSON.stringify({ level: "error", at: "appointments.inviteMail", message: (e as Error).message })); return go(req, back, { error: "inviteMail" }); }
      return go(req, back, { saved: "invited" });
    }
    if (action === "withdraw_invite" && UUID.test(String(form.get("invite_id") ?? ""))) {
      await withdrawOwnerInvite(auth.session, String(form.get("invite_id")));
      return go(req, back, { saved: "inviteWithdrawn" });
    }
    if ((action === "accept" || action === "decline") && UUID.test(id)) {
      // Founder ruling 19 Nov 2026: an owner with no trademarks yet accepts with none and chooses them later;
      // an owner who has trademarks still chooses at least one
      if (action === "accept" && auth.session.accountKind !== "agency_office" && records.length === 0
          && (await listPortfolio(auth.session)).length > 0) return go(req, back, { error: "noRecords" });
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
    const all = `${err.cause?.message ?? ""} ${err.message}`;
    if (/owner_invite_one_pending/.test(all)) return go(req, back, { error: "inviteOpen" });
    if (/does not belong to an owner/.test(all)) return go(req, back, { error: "notOwner" });
    if (/invitation limit reached/.test(all)) return go(req, back, { error: "inviteLimit" });
    if (err.cause?.constraint_name === "appointment_one_open" || /appointment_one_open/.test(err.cause?.message ?? err.message)) return go(req, back, { error: "alreadyOpen" });
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { error: "generic" });
}
