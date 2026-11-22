import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { addFeedback } from "@/lib/public";

export const runtime = "nodejs";

/** Feedback from a signed-in user (ruling R11; migration 0077): the account and user come from the session, never from the form. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  const back = `/${locale}/feedback`;
  const body = String(form.get("body") ?? "").trim();
  if (body.length < 5 || body.length > 4000) return go(req, back, { error: "length" });
  try {
    const r = await addFeedback(session, body, String(form.get("page") ?? "").slice(0, 200) || null, locale);
    return go(req, back, r === "ok" ? { saved: "1" } : { error: "limit" });
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "feedback", message: (e as Error).message }));
    return go(req, back, { error: "generic" });
  }
}
