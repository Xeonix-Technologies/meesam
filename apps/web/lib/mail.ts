import { pickText, translator, type Locale } from "@meesam/i18n";

/**
 * System mail through Postmark (ruled 14 Nov 2026). Server token in EMAIL_PROVIDER_KEY (sealed),
 * sender in EMAIL_FROM. Without a token (local dev) the message is logged, not sent.
 */
export async function sendMail(to: string, subject: string, text: string, html?: string): Promise<void> {
  const token = process.env.EMAIL_PROVIDER_KEY;
  const from = process.env.EMAIL_FROM ?? "Meesam <no-reply@meesam.ae>";
  if (!token) {
    console.log(JSON.stringify({ level: "warn", at: "mail.skipped", message: "mail not sent: EMAIL_PROVIDER_KEY is not set", subject }));
    return;
  }
  const res = await fetch("https://api.postmarkapp.com/email", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json", "X-Postmark-Server-Token": token },
    body: JSON.stringify({ From: from, To: to, Subject: subject, TextBody: text, HtmlBody: html ?? textToHtml(text), MessageStream: process.env.EMAIL_STREAM ?? "outbound" }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error(JSON.stringify({ level: "error", at: "mail.failed", message: `mail refused by the e-mail service (${res.status}): ${body.slice(0, 300)}`, status: res.status }));
    throw new Error(`mail provider returned ${res.status}`);
  }
}

function textToHtml(text: string): string {
  const esc = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const linked = esc.replace(/(https?:\/\/[^\s]+)/g, '<a href="$1">$1</a>');
  return `<pre style="font-family:inherit;white-space:pre-wrap">${linked}</pre>`;
}

/** APP_URL, tolerant of a value pasted as "APP_URL = https://…" or with a trailing slash. */
export function appUrl(): string {
  const raw = process.env.APP_URL ?? "";
  const m = raw.match(/https?:\/\/[^\s'"<>]+/);
  if (!m) return "http://localhost:3000";
  if (m[0] !== raw.trim()) console.warn(JSON.stringify({ level: "warn", at: "config.APP_URL", message: "APP_URL contains extra text; using the URL inside it" }));
  return m[0].replace(/\/+$/, "");
}

/** APP_URL when it is a well-formed link, else null (the caller then takes the origin from the request). A malformed value is logged, never thrown at a visitor. */
export function appUrlOrNull(): string | null {
  if (!process.env.APP_URL) return null;
  const u = appUrl();
  try { new URL("/", u); return u; } catch {
    console.error(JSON.stringify({ level: "error", at: "config.APP_URL", message: "APP_URL is not a valid link; using the request's own address" }));
    return null;
  }
}

export async function sendVerifyMail(to: string, name: string, locale: Locale, token: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/verify-email?token=${encodeURIComponent(token)}`;
  await sendMail(to, t("mail.verify.subject"), t("mail.verify.body", { name, link }), mailHtml(locale, t("mail.verify.body", { name, link }), link, t("mail.verify.button")));
}

export async function sendResetMail(to: string, name: string, locale: Locale, token: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/reset-password?token=${encodeURIComponent(token)}`;
  await sendMail(to, t("mail.reset.subject"), t("mail.reset.body", { name, link }), mailHtml(locale, t("mail.reset.body", { name, link }), link, t("mail.reset.button")));
}

/** Invitation to join a company or agency account as one of its users (link valid 7 days). */
export async function sendInviteMail(to: string, name: string, locale: Locale, token: string, account: string, by: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/accept-invite?token=${encodeURIComponent(token)}`;
  const body = t("mail.invite.body", { name, link, account, by });
  await sendMail(to, t("mail.invite.subject", { account }), body, mailHtml(locale, body, link, t("mail.invite.button")));
}

/** Appointment events told to the other side: requested, accepted, declined, ended, scope. */
export async function sendAppointmentMail(to: string, name: string, locale: Locale, kind: "requested" | "accepted" | "declined" | "ended" | "scope", from: string, path: string, note: string, forAccount: string): Promise<void> {
  const t = translator(locale);
  // "for" names the account the message was sent to, so the page can say so when the browser is signed in to another one
  const link = `${appUrl()}/${locale}/${path}?for=${forAccount}`;
  const body = t(`mail.appointment.${kind}.body`, { name, from, link, note: note || "—" });
  await sendMail(to, t(`mail.appointment.${kind}.subject`, { from }), body, mailHtml(locale, body, link, t("mail.appointment.button")));
}

/** An agency invites an owner who has no Meesam account yet: a link to create one, with the address filled in. */
export async function sendOwnerInviteMail(to: string, locale: Locale, agency: string, note: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/create-account?email=${encodeURIComponent(to)}`;
  const body = t("mail.ownerInvite.body", { agency, link, note: note || "—" });
  await sendMail(to, t("mail.ownerInvite.subject", { agency }), body, mailHtml(locale, body, link, t("mail.ownerInvite.button")));
}

/** Cross-border instruction events told to the other office: requested, accepted, declined, ended. */
export async function sendInstructionMail(to: string, name: string, locale: Locale, kind: "requested" | "accepted" | "declined" | "ended", from: string, mark: string, note: string, forAccount: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/instructions?for=${forAccount}`;
  const body = t(`mail.instruction.${kind}.body`, { name, from, mark, link, note: note || "—" });
  await sendMail(to, t(`mail.instruction.${kind}.subject`, { from, mark }), body, mailHtml(locale, body, link, t("mail.appointment.button")));
}

/** To the staff: an owner account was verified by an agency's invitation, without review (Founder ruling 19 Nov 2026). */
export async function sendStaffInviteVerifiedMail(to: string, name: string, locale: Locale, owner: Record<string, string>, email: string, agency: Record<string, string>): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/admin`;
  const body = t("mail.staffInviteVerified.body", { name, owner: pickText(owner, locale) || "—", email, agency: pickText(agency, locale) || "—", link });
  await sendMail(to, t("mail.staffInviteVerified.subject", { owner: pickText(owner, locale) || email }), body, mailHtml(locale, body, link, t("mail.appointment.button")));
}

/** An agency office that is not on Meesam is invited to receive an instruction: a link to create an agency account with the address filled in. */
export async function sendOfficeInviteMail(to: string, locale: Locale, from: string, mark: string, note: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/create-account/agency?email=${encodeURIComponent(to)}`;
  const body = t("mail.officeInvite.body", { from, mark, link, note: note || "—" });
  await sendMail(to, t("mail.officeInvite.subject", { from }), body, mailHtml(locale, body, link, t("mail.officeInvite.button")));
}

/** A deadline was assigned to this user by a colleague in the same account. */
export async function sendTimerAssignedMail(to: string, name: string, locale: Locale, by: string, what: string, mark: string, date: string, recordId: string, forAccount: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/records/${recordId}?for=${forAccount}`;
  const body = t("mail.timerAssigned.body", { name, by, what, mark, date, link });
  await sendMail(to, t("mail.timerAssigned.subject", { what, mark }), body, mailHtml(locale, body, link, t("mail.reminder.button")));
}

/** A new message on a record's thread, told to the other side with the text and a link to the thread. */
export async function sendMessageMail(to: string, name: string, locale: Locale, from: string, author: string, mark: string, text: string, recordId: string, forAccount: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/records/${recordId}?tab=messages&for=${forAccount}`;
  const body = t("mail.message.body", { name, from, author, mark: mark || "—", text, link });
  await sendMail(to, t("mail.message.subject", { from, mark: mark || "—" }), body, mailHtml(locale, body, link, t("mail.message.button")));
}

/** Owner pass sent by the agency to its client: the code and a link that opens it (valid 30 days, single use). */
export async function sendPassMail(to: string, locale: Locale, agency: string, mark: string, code: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/pass?code=${encodeURIComponent(code)}`;
  const body = t("mail.pass.body", { agency, mark: mark || "—", code, link });
  await sendMail(to, t("mail.pass.subject", { agency, mark: mark || "—" }), body, mailHtml(locale, body, link, t("mail.pass.button")));
}

/** Tells the owner that the agency took back a trademark it had handed over by pass. */
export async function sendTakenBackMail(to: string, name: string, locale: Locale, agency: string, mark: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/records`;
  const body = t("mail.takenBack.body", { name, agency, mark: mark || "—", link });
  await sendMail(to, t("mail.takenBack.subject", { agency, mark: mark || "—" }), body, mailHtml(locale, body, link, t("mail.appointment.button")));
}

/** The sign-in code of two-factor sign-in (valid 15 minutes, single use). */
export async function sendLoginCodeMail(to: string, locale: Locale, code: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/login/verify`;
  const body = t("mail.loginCode.body", { code, link });
  await sendMail(to, t("mail.loginCode.subject", { code }), body, mailHtml(locale, body, link, t("mail.loginCode.button")));
}

/** Tells an account's users the outcome of the verification review. */
export async function sendReviewMail(to: string, name: string, locale: Locale, approved: boolean, note: string): Promise<void> {
  const t = translator(locale);
  const link = `${appUrl()}/${locale}/login`;
  const key = approved ? "mail.verified" : "mail.rejected";
  const body = t(`${key}.body`, { name, link, note: note || "—" });
  await sendMail(to, t(`${key}.subject`), body, mailHtml(locale, body, link, t(`${key}.button`)));
}

function mailHtml(locale: Locale, text: string, link: string, button: string): string {
  const dir = locale === "ar" ? "rtl" : "ltr";
  const body = text
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(link.replace(/&/g, "&amp;"), "")
    .split("\n\n")
    .map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`)
    .join("");
  // Brand header: the bilingual wordmark (reversed) on the ink band, the same in light and dark mail clients.
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
