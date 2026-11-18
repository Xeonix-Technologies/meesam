import { isLocale, pickText } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { messageRecipients, postMessage } from "@/lib/messages";
import { sendMessageMail } from "@/lib/mail";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Posts a message on the record's thread (item 39 (vi)); the other side's users are told by e-mail. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const body = String(form.get("body") ?? "").trim().slice(0, 4000);
  const mark = String(form.get("mark") ?? "").slice(0, 200);
  if (!UUID.test(id)) return go(req, `/${locale}/records`);
  if (!body) return go(req, back, { tab: "messages", error: "messageEmpty" });
  let messageId: string;
  try {
    messageId = await postMessage(auth.session, id, body);
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    console.error(JSON.stringify({ level: "error", at: "records.messages", message: err.message, cause: err.cause?.message, code: err.cause?.code }));
    return go(req, back, { tab: "messages", error: /no holding agency/.test(err.cause?.message ?? err.message) ? "messageNoAgency" : "generic" });
  }
  try {
    const to = await messageRecipients(auth.session, messageId);
    await Promise.allSettled(to.map((u) => { const l = u.locale === "ar" ? "ar" : "en"; return sendMessageMail(u.email, u.name, l, pickText(auth.session.accountName, l) || auth.session.userName, auth.session.userName, mark, body, id, u.account_id); }));
  } catch (e) { console.error(JSON.stringify({ level: "error", at: "records.messages.mail", message: (e as Error).message })); }
  return go(req, back, { tab: "messages", saved: "message" });
}
