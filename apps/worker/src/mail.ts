import { formatDate, pickText, translator, type Locale } from "@meesam/i18n";

/**
 * Mail sent by the worker (deadline reminders). Same provider and brand frame as the web service
 * (Postmark, ruled 14 Nov 2026): server token in EMAIL_PROVIDER_KEY, sender in EMAIL_FROM, links from APP_URL.
 */
export const mailConfigured = (): boolean => Boolean(process.env.EMAIL_PROVIDER_KEY);

function appUrl(): string {
  const m = (process.env.APP_URL ?? "").match(/https?:\/\/[^\s'"<>]+/);
  return m ? m[0].replace(/\/+$/, "") : "http://localhost:3000";
}

async function sendMail(to: string, subject: string, text: string, html: string): Promise<void> {
  const token = process.env.EMAIL_PROVIDER_KEY;
  if (!token) throw new Error("EMAIL_PROVIDER_KEY not set");
  const res = await fetch("https://api.postmarkapp.com/email", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json", "X-Postmark-Server-Token": token },
    body: JSON.stringify({ From: process.env.EMAIL_FROM ?? "Meesam <no-reply@meesam.ae>", To: to, Subject: subject, TextBody: text, HtmlBody: html, MessageStream: process.env.EMAIL_STREAM ?? "outbound" }),
  });
  if (!res.ok) throw new Error(`mail provider returned ${res.status}: ${(await res.text()).slice(0, 200)}`);
}

function mailHtml(locale: Locale, text: string, link: string, button: string): string {
  const dir = locale === "ar" ? "rtl" : "ltr";
  const body = text
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(link.replace(/&/g, "&amp;"), "")
    .split("\n\n")
    .map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`)
    .join("");
  const logo = `${appUrl()}/brand/meesam-reversed.png`;
  return `<!doctype html><html lang="${locale}" dir="${dir}"><body style="margin:0;padding:0;background:#f5f2ea;font-family:system-ui,-apple-system,'Segoe UI',sans-serif;color:#121a2b">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f2ea"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border:1px solid #e3ded2;border-radius:10px;overflow:hidden">
<tr><td style="background:#121a2b;padding:18px 24px"><img src="${logo}" alt="ميسم Meesam" height="26" style="display:block;height:26px;width:auto;border:0"></td></tr>
<tr><td style="padding:24px;font-size:15px;line-height:1.6">${body}
<p style="margin:24px 0 8px"><a href="${link.replace(/&/g, "&amp;")}" style="background:#121a2b;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">${button}</a></p>
<p style="color:#6b7280;font-size:12px;margin:0;word-break:break-all">${link}</p></td></tr>
</table></td></tr></table></body></html>`;
}

export interface ReminderMail {
  id: string; email: string; name: string; locale: string; account_id: string; record_id: string; severity: string; point: string;
  timer_type: string; due_date: string | Date; days: number; timezone: string; mark_text: Record<string, string> | null; number: string | null; registry_code: string;
}

/**
 * One deadline reminder (System Description 4.11). The wording states what Meesam computed and asks the reader to
 * check it against the registry: Meesam computes expectations and never asserts registry facts (item 44 v).
 */
export async function sendReminderMail(m: ReminderMail): Promise<void> {
  const locale: Locale = m.locale === "ar" ? "ar" : "en";
  const t = translator(locale);
  const months = /_reminder_(\d+)m$/.exec(m.timer_type)?.[1];
  const what = months
    ? t("timers.renewalReminder", { months: months === "1" ? t("timers.oneMonth") : t("timers.nMonths", { n: months }) })
    : t(`timers.${m.timer_type}`);
  const mark = `${pickText(m.mark_text, locale) || m.number || "—"} (${m.registry_code}${m.number ? ` ${m.number}` : ""})`;
  const date = formatDate(typeof m.due_date === "string" ? m.due_date : m.due_date.toISOString().slice(0, 10), locale);
  const days = Number(m.days);
  const left = days > 1 ? t("mail.reminder.left", { days }) : days === 1 ? t("mail.reminder.leftOne") : days === 0 ? t("mail.reminder.today") : t("mail.reminder.past", { days: -days });
  const link = `${appUrl()}/${locale}/records/${m.record_id}?for=${m.account_id}`;
  const extra = m.timer_type === "expiry" && days <= 0 ? `\n${t("mail.reminder.expiryNote")}` : m.timer_type === "renewal_window" ? `\n${t("mail.reminder.windowNote")}` : "";
  // a renewal reminder counts down to the expiry date, so it is worded around the expiry
  const body = t(months ? "mail.reminder.bodyRenewal" : "mail.reminder.body", { name: m.name, what, mark, date, left, timezone: m.timezone, link, extra });
  const subject = t(m.severity === "critical" ? "mail.reminder.subjectCritical" : "mail.reminder.subject", { what, mark, left });
  await sendMail(m.email, subject, body, mailHtml(locale, body, link, t("mail.reminder.button")));
}
