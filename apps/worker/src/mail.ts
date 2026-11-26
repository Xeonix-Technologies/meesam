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
  /** nobody in the reader's account has acknowledged this deadline (escalation, 4.11) */
  unack?: boolean;
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
  const extra = (m.timer_type === "expiry" && days <= 0 ? `\n${t("mail.reminder.expiryNote")}` : m.timer_type === "renewal_window" ? `\n${t("mail.reminder.windowNote")}` : "")
    + (m.unack ? `\n\n${t("mail.reminder.unackNote")}` : "");
  // a renewal reminder counts down to the expiry date, so it is worded around the expiry
  const body = t(months ? "mail.reminder.bodyRenewal" : "mail.reminder.body", { name: m.name, what, mark, date, left, timezone: m.timezone, link, extra });
  const subject = t(m.unack ? "mail.reminder.subjectUnack" : m.severity === "critical" ? "mail.reminder.subjectCritical" : "mail.reminder.subject", { what, mark, left });
  await sendMail(m.email, subject, body, mailHtml(locale, body, link, t("mail.reminder.button")));
}

export interface DigestRow {
  user_id: string; email: string; name: string; locale: string; account_id: string; item: "reminder" | "changes"; record_id: string;
  mark_text: Record<string, string> | null; number: string | null; registry_code: string; timer_type: string | null; due_date: string | Date | null; days: number | null; changes: number | null;
}

/** The daily summary for one user (System Description 4.11): Important reminders the user chose to receive here, and trademarks the other side changed. */
export async function sendDigestMail(rows: DigestRow[]): Promise<void> {
  const first = rows[0];
  if (!first) return;
  const locale: Locale = first.locale === "ar" ? "ar" : "en";
  const t = translator(locale);
  const markOf = (r: DigestRow) => `${pickText(r.mark_text, locale) || r.number || "—"} (${r.registry_code}${r.number ? ` ${r.number}` : ""})`;
  const reminders = rows.filter((r) => r.item === "reminder").map((r) => {
    const months = /_reminder_(\d+)m$/.exec(r.timer_type ?? "")?.[1];
    const what = months ? t("timers.renewalReminder", { months: months === "1" ? t("timers.oneMonth") : t("timers.nMonths", { n: months }) }) : t(`timers.${r.timer_type}`);
    const days = Number(r.days ?? 0);
    const left = days > 1 ? t("mail.reminder.left", { days }) : days === 1 ? t("mail.reminder.leftOne") : days === 0 ? t("mail.reminder.today") : t("mail.reminder.past", { days: -days });
    const date = r.due_date ? formatDate(typeof r.due_date === "string" ? r.due_date : r.due_date.toISOString().slice(0, 10), locale) : "—";
    return `• ${what} — ${markOf(r)}: ${date} (${left})`;
  });
  const changes = rows.filter((r) => r.item === "changes").map((r) => `• ${markOf(r)}: ${Number(r.changes) === 1 ? t("mail.digest.oneChange") : t("mail.digest.nChanges", { n: Number(r.changes) })}`);
  const parts: string[] = [];
  if (reminders.length) parts.push(`${t("mail.digest.reminders")}\n${reminders.join("\n")}`);
  if (changes.length) parts.push(`${t("mail.digest.changes")}\n${changes.join("\n")}`);
  const link = `${appUrl()}/${locale}/dashboard?for=${first.account_id}`;
  const body = t("mail.digest.body", { name: first.name, content: parts.join("\n\n"), link });
  await sendMail(first.email, t("mail.digest.subject", { date: formatDate(new Date(), locale) }), body, mailHtml(locale, body, link, t("mail.digest.button")));
}

export interface ManualReminder { source_id: string; registry_code: string; registry_name: Record<string, string> | null; stream: string; due_on: string | Date; last_issue: string | null; where_from: string | null; email: string; name: string; locale: string }

/** A by-hand source is due (temporary ruling of 19 Nov 2026): tells the watch operations lead which issue to fetch and where to add it. */
export async function sendManualReminderMail(m: ManualReminder): Promise<void> {
  const locale: Locale = m.locale === "ar" ? "ar" : "en";
  const t = translator(locale);
  const registry = `${m.registry_code} · ${pickText(m.registry_name, locale)}`;
  const link = `${appUrl()}/${locale}/ops/inbox#by-hand`;
  const date = formatDate(typeof m.due_on === "string" ? m.due_on : m.due_on.toISOString().slice(0, 10), locale);
  const body = t("mail.opsManual.body", { name: m.name, registry, stream: t(`ops.streams.${m.stream}`), date, last: m.last_issue ?? t("mail.opsManual.none"), where: m.where_from ?? "—", link });
  await sendMail(m.email, t("mail.opsManual.subject", { registry }), body, mailHtml(locale, body, link, t("mail.opsManual.button")));
}

export interface AlertMail { email: string; name: string; locale: string; account_id: string; kind: "new" | "reminder"; alerts: number; high: number; nearest_deadline: string | Date | null; days_left: number | null;
  /** the marks the alerts are about (migration 0083): shown in the e-mail, strongest first */
  items?: Array<{ mark: string | null; registry: string; score: number; band: string; same_class: boolean; classes: number[] }> | null }

/**
 * Watch alerts (MSM-PRD-02 Section 8.2): new alerts for an account, or a reminder that alerts are still new while the
 * time to oppose runs out. The wording describes; it never says a mark is likely to be confused with another.
 */
export async function sendAlertMail(m: AlertMail): Promise<void> {
  const locale: Locale = m.locale === "ar" ? "ar" : "en";
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/alerts?for=${m.account_id}`;
  const n = Number(m.alerts);
  const count = n === 1 ? t("mail.alert.one") : t("mail.alert.many", { n });
  const high = Number(m.high) > 0 ? `\n${t("mail.alert.high", { n: Number(m.high) })}` : "";
  const date = m.nearest_deadline ? formatDate(typeof m.nearest_deadline === "string" ? m.nearest_deadline : m.nearest_deadline.toISOString().slice(0, 10), locale) : null;
  // a period that has ended is said in words, never as a negative number of days
  const left = Number(m.days_left ?? 0);
  const deadline = !date ? `\n${t("mail.alert.noDeadline")}` : left < 0 ? `\n${t("mail.alert.deadlinePassed", { date })}` : `\n${t("mail.alert.deadline", { date, days: left })}`;
  // each mark by name: the published mark, its registry, the likeness and whether a class is shared (Founder ruling 22 Nov 2026)
  const items = Array.isArray(m.items) ? m.items : [];
  const lines = items.map((x) => `• ${t("mail.alert.item", { mark: x.mark ?? t("mail.alert.noWording"), registry: x.registry, score: Number(x.score), band: t(`alerts.band.${x.band}`),
    cls: x.same_class ? t("mail.alert.sameClass") : t("mail.alert.otherClass") })}`);
  if (n > items.length && items.length) lines.push(t("mail.alert.more", { n: n - items.length }));
  const list = lines.length ? `\n\n${lines.join("\n")}` : "";
  const main = t(m.kind === "reminder" ? "mail.alert.bodyReminder" : "mail.alert.body", { name: m.name, count, high: `${high}${deadline}${list}`, deadline: "", link });
  // Founder, 26 Nov 2026: wherever Meesam shows a trademark it says whose the trademarks are; the alert e-mail names published marks.
  const body = `${main}\n\n${t("footer.trademarks")}`;
  await sendMail(m.email, t(m.kind === "reminder" ? "mail.alert.subjectReminder" : "mail.alert.subject", { count }), body, mailHtml(locale, body, link, t("mail.alert.button")));
}
