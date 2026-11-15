import { translator, type Locale } from "@meesam/i18n";

/**
 * System mail through Postmark (ruled 14 Nov 2026). Server token in EMAIL_PROVIDER_KEY (sealed),
 * sender in EMAIL_FROM. Without a token (local dev) the message is logged, not sent.
 */
export async function sendMail(to: string, subject: string, text: string, html?: string): Promise<void> {
  const token = process.env.EMAIL_PROVIDER_KEY;
  const from = process.env.EMAIL_FROM ?? "Meesam <no-reply@meesam.ae>";
  if (!token) {
    console.log(JSON.stringify({ level: "info", at: "mail.skipped", to, subject }));
    return;
  }
  const res = await fetch("https://api.postmarkapp.com/email", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json", "X-Postmark-Server-Token": token },
    body: JSON.stringify({ From: from, To: to, Subject: subject, TextBody: text, HtmlBody: html ?? textToHtml(text), MessageStream: process.env.EMAIL_STREAM ?? "outbound" }),
  });
  if (!res.ok) {
    const body = await res.text();
    console.error(JSON.stringify({ level: "error", at: "mail.failed", status: res.status, body: body.slice(0, 300) }));
    throw new Error(`mail provider returned ${res.status}`);
  }
}

function textToHtml(text: string): string {
  const esc = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const linked = esc.replace(/(https?:\/\/[^\s]+)/g, '<a href="$1">$1</a>');
  return `<pre style="font-family:inherit;white-space:pre-wrap">${linked}</pre>`;
}

export function appUrl(): string {
  return (process.env.APP_URL ?? "http://localhost:3000").replace(/\/$/, "");
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

function mailHtml(locale: Locale, text: string, link: string, button: string): string {
  const dir = locale === "ar" ? "rtl" : "ltr";
  const body = text
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(link, "")
    .split("\n\n")
    .map((p) => `<p>${p.replace(/\n/g, "<br>")}</p>`)
    .join("");
  return `<!doctype html><html lang="${locale}" dir="${dir}"><body style="font-family:system-ui,sans-serif;max-width:560px;margin:0 auto;padding:24px;color:#1a1a1a">
<p style="font-size:20px;font-weight:700;margin:0 0 16px">ميسم · Meesam</p>${body}
<p style="margin:24px 0"><a href="${link}" style="background:#1f6f5f;color:#fff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">${button}</a></p>
<p style="color:#666;font-size:12px">${link}</p></body></html>`;
}
