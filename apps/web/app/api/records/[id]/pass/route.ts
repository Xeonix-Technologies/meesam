import { isLocale, pickText } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { EMAIL_RE } from "@/lib/auth";
import { issuePass, takeBack } from "@/lib/pass";
import { sendPassMail, sendTakenBackMail } from "@/lib/mail";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * An agency issues an owner pass for a record it holds (4.4 link 2). The code is shown once on the next page
 * (kept for a few minutes in a cookie only this browser sends) and, if an address is given, e-mailed to the owner.
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  if (!UUID.test(id)) return go(req, `/${locale}/records`);
  // Founder ruling 18 Nov 2026: the side that issued the pass takes the record back, no confirmation by the other side
  if (form.get("action") === "takeback") {
    const markName = String(form.get("mark") ?? "").slice(0, 200);
    try {
      const to = await takeBack(auth.session, id);
      await Promise.allSettled(to.map((u) => { const l = u.locale === "ar" ? "ar" : "en"; return sendTakenBackMail(u.email, u.name, l, pickText(auth.session.accountName, l) || auth.session.userName, markName); }));
      return go(req, back, { tab: "agencies", saved: "passTakenBack" });
    } catch (e) {
      const err = e as Error & { cause?: { message?: string } };
      console.error(JSON.stringify({ level: "error", at: "records.pass.takeback", message: err.message, cause: err.cause?.message }));
      return go(req, back, { tab: "agencies", error: "passTakeBack" });
    }
  }
  const email = String(form.get("email") ?? "").trim().toLowerCase().slice(0, 200);
  const mark = String(form.get("mark") ?? "").slice(0, 200);
  const mailLocale = form.get("mail_locale") === "ar" ? "ar" : "en";
  if (email && !EMAIL_RE.test(email)) return go(req, back, { tab: "agencies", error: "passEmail" });
  let code: string;
  try {
    code = await issuePass(auth.session, id, email || null);
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    console.error(JSON.stringify({ level: "error", at: "records.pass", message: err.message, cause: err.cause?.message, code: err.cause?.code }));
    return go(req, back, { tab: "agencies", error: "pass" });
  }
  let mailed = "";
  if (email) {
    try { await sendPassMail(email, mailLocale, pickText(auth.session.accountName, mailLocale) || auth.session.userName, mark, code); mailed = "sent"; }
    catch (e) { console.error(JSON.stringify({ level: "error", at: "records.pass.mail", message: (e as Error).message })); mailed = "failed"; }
  }
  const res = go(req, back, { tab: "agencies", saved: mailed === "failed" ? "passNoMail" : mailed === "sent" ? "passSent" : "pass" });
  res.cookies.set(`ms_pass_${id}`, code, { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: 300 });
  return res;
}
