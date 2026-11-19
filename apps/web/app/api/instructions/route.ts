import { isLocale, pickText } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { endInstruction, instructionRecipients, listInstructions, requestInstruction, respondInstruction } from "@/lib/instructions";
import { sendInstructionMail } from "@/lib/mail";
import type { Session } from "@/lib/session";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** E-mails the other office's users; a mail failure never undoes the action (the in-app notice is already written). */
async function tell(s: Session, id: string, kind: "requested" | "accepted" | "declined" | "ended", note = ""): Promise<void> {
  try {
    const [to, list] = await Promise.all([instructionRecipients(s, id), listInstructions(s)]);
    const i = list.find((x) => x.id === id);
    await Promise.allSettled(to.map((u) => { const l = u.locale === "ar" ? "ar" : "en";
      return sendInstructionMail(u.email, u.name, l, kind, pickText(s.accountName, l), i ? `${pickText(i.mark_text, l) || i.number || "—"} (${i.registry_code})` : "—", note, u.account_id); }));
  } catch (e) { console.error(JSON.stringify({ level: "error", at: "instructions.mail", kind, message: (e as Error).message })); }
}

/** One entry point for cross-border instruction actions; the database functions decide who may do what (migration 0027). */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const action = String(form.get("action") ?? "");
  const id = String(form.get("instruction_id") ?? "");
  const recordId = String(form.get("record_id") ?? "");
  // a form on the record page comes back to the record; the others to the Instructions page
  const back = UUID.test(recordId) && form.get("from") === "record" ? `/${locale}/records/${recordId}` : `/${locale}/instructions`;
  const extra: Record<string, string> = back.includes("/records/") ? { tab: "agencies" } : {};
  const text = (k: string, n: number) => String(form.get(k) ?? "").trim().slice(0, n);
  try {
    if (action === "request" && UUID.test(recordId)) {
      const to = String(form.get("account_id") ?? "");
      const email = text("email", 254).toLowerCase();
      if (!UUID.test(to) && !EMAIL.test(email)) return go(req, back, { ...extra, error: "instrWho" });
      const newId = await requestInstruction(auth.session, recordId, UUID.test(to) ? to : null, UUID.test(to) ? null : email, text("message", 1000));
      await tell(auth.session, newId, "requested", text("message", 1000));
      return go(req, back, { ...extra, saved: "instrRequested" });
    }
    if ((action === "accept" || action === "decline") && UUID.test(id)) {
      await respondInstruction(auth.session, id, action === "accept", text("note", 500));
      await tell(auth.session, id, action === "accept" ? "accepted" : "declined", text("note", 500));
      return go(req, back, { ...extra, saved: action === "accept" ? "instrAccepted" : "instrDeclined" });
    }
    if (action === "end" && UUID.test(id)) {
      await endInstruction(auth.session, id);
      await tell(auth.session, id, "ended");
      return go(req, back, { ...extra, saved: "instrEnded" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    const all = `${err.cause?.message ?? ""} ${err.message}`;
    console.error(JSON.stringify({ level: "error", at: "instructions", action, message: err.message, cause: err.cause?.message, code: err.cause?.code }));
    if (/instruction_one_open/.test(all)) return go(req, back, { ...extra, error: "instrOpen" });
    if (/other office is not available/.test(all)) return go(req, back, { ...extra, error: "instrOffice" });
    if (/not allowed for this user|only the instructed office|only the owner or an office/.test(all)) return go(req, back, { ...extra, error: "instrRole" });
    return go(req, back, { ...extra, error: "instrGeneric" });
  }
  return go(req, back, { ...extra, error: "instrGeneric" });
}
