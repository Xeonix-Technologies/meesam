import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { addStageChange } from "@/lib/records";

export const runtime = "nodejs";
const EVENTS = ["filed", "formal_ok", "office_action", "response_filed", "accepted", "published", "opposed", "appealed", "registered", "declaration_of_use", "recordal", "renewal_window", "renewed", "expired", "challenged", "enforcement", "cancelled", "refused", "withdrawn"];

/** 3.7 Record a stage change. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const type = String(form.get("event_type") ?? "");
  const date = String(form.get("event_date") ?? "");
  const number = String(form.get("number") ?? "").trim().slice(0, 60) || null;
  const status = String(form.get("registry_status") ?? "").trim().slice(0, 200) || null;
  const back = `/${locale}/records/${id}`;
  if (!EVENTS.includes(type) || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return go(req, back, { error: "event", tab: "timeline" });
  try {
    await addStageChange(auth.session, id, type, date, number, status);
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "record.event", message: (err as Error).message }));
    return go(req, back, { error: "generic", tab: "timeline" });
  }
  return go(req, back, { tab: "timeline", saved: "1" });
}
