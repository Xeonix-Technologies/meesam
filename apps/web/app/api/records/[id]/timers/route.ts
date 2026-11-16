import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { enterDeadline, getRecord } from "@/lib/records";

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
  const due = String(form.get("due_date") ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(timerId) || !/^\d{4}-\d{2}-\d{2}$/.test(due)) return go(req, `/${locale}/records/${id}`, { error: "event" });
  const record = await getRecord(auth.session, id);
  const tz = record?.rules?.calendar.timezone ?? "UTC";
  await enterDeadline(auth.session, timerId, due, tz);
  return go(req, `/${locale}/records/${id}`, { saved: "1" });
}
