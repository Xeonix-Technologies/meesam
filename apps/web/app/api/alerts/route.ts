import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { DISMISS_REASONS, setAlert } from "@/lib/alerts";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * An account acts on one of its own watch alerts: reviewed, opposition recorded, dismissed with a reason, or back to
 * new. The database checks that the alert belongs to the account, requires the deadline where none is computed, and
 * audits the change (migration 0069).
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/alerts`;
  const view = String(form.get("view") ?? "");
  const keep: Record<string, string> = view === "new" || view === "all" ? { view } : {};
  const id = String(form.get("id") ?? "");
  const action = String(form.get("action") ?? "");
  if (!UUID.test(id) || !["new", "reviewing", "actioned", "dismissed"].includes(action)) return go(req, back, { ...keep, error: "generic" });
  const reason = String(form.get("reason") ?? "");
  const deadline = String(form.get("deadline") ?? "").trim();
  if (action === "dismissed" && !(DISMISS_REASONS as readonly string[]).includes(reason)) return go(req, back, { ...keep, error: "reason" }, `a-${id}`);
  if (deadline && !/^\d{4}-\d{2}-\d{2}$/.test(deadline)) return go(req, back, { ...keep, error: "deadline" }, `a-${id}`);
  try {
    await setAlert(auth.session, id, action, action === "dismissed" ? reason : null, deadline || null);
    return go(req, back, { ...keep, saved: action });
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    if (err.cause?.code === "22004") return go(req, back, { ...keep, error: "deadline" }, `a-${id}`);
    console.error(JSON.stringify({ level: "error", at: "alerts", action, message: err.cause?.message ?? err.message }));
    return go(req, back, { ...keep, error: "generic" });
  }
}
