import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { enterDeadline, getRecord } from "@/lib/records";
import { acknowledgeTimer, assignTimer, assignableUsers } from "@/lib/timerAcks";
import { timerLabel } from "@/lib/timers";
import { sendTimerAssignedMail } from "@/lib/mail";

export const runtime = "nodejs";

/** The user enters a deadline the registry profile could not supply (item 44). */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const timerId = String(form.get("timer_id") ?? "");
  // acknowledge or assign a deadline (System Description 4.11); the database decides who may
  const action = String(form.get("action") ?? "");
  if ((action === "ack" || action === "assign") && /^[0-9a-f-]{36}$/i.test(timerId)) {
    const back = `/${locale}/records/${id}`;
    try {
      if (action === "ack") { await acknowledgeTimer(auth.session, timerId); return go(req, back, { saved: "timerAck" }, "next-dates"); }
      const to = String(form.get("user_id") ?? "");
      const userId = /^[0-9a-f-]{36}$/i.test(to) ? to : null;
      await assignTimer(auth.session, timerId, userId);
      if (userId && userId !== auth.session.userId) {
        try {
          const [users, rec] = await Promise.all([assignableUsers(auth.session), getRecord(auth.session, id)]);
          const u = users.find((x) => x.id === userId);
          const tm = rec?.timers.find((x) => x.id === timerId);
          if (u && rec && tm?.due_date) {
            const l = u.locale === "ar" ? "ar" : "en";
            await sendTimerAssignedMail(u.email, u.name, l, auth.session.userName, timerLabel(translator(l), tm.timer_type),
              `${pickText(rec.mark_text, l) || rec.registration_no || rec.application_no || "—"} (${rec.registry_code})`, formatDate(tm.due_date, l), id, auth.session.accountId);
          }
        } catch (e) { console.error(JSON.stringify({ level: "error", at: "timers.assign.mail", message: (e as Error).message })); }
      }
      return go(req, back, { saved: userId ? "timerAssigned" : "timerUnassigned" }, "next-dates");
    } catch (e) {
      console.error(JSON.stringify({ level: "error", at: "timers.ack", action, message: (e as Error).message }));
      return go(req, back, { error: "timerAck" }, "next-dates");
    }
  }
  const due = String(form.get("due_date") ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(timerId) || !/^\d{4}-\d{2}-\d{2}$/.test(due)) return go(req, `/${locale}/records/${id}`, { error: "event" });
  const record = await getRecord(auth.session, id);
  const tz = record?.rules?.calendar.timezone ?? "UTC";
  await enterDeadline(auth.session, timerId, due, tz);
  return go(req, `/${locale}/records/${id}`, { saved: "1" });
}
