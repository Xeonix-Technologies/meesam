import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { setWatchRegistry } from "@/lib/alerts";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Watch scope of a trademark (MSM-PRD-02 Section 7): the holding account adds a registry Meesam reads, or removes
 * one it added. The database checks access, audits the change and notifies the other side (migration 0070).
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const registry = String(form.get("registry_id") ?? "");
  const action = String(form.get("action") ?? "");
  if (!UUID.test(id) || !UUID.test(registry) || (action !== "add" && action !== "remove")) return go(req, back, { tab: "watch", error: "generic" });
  try {
    await setWatchRegistry(auth.session, id, registry, action === "add");
    return go(req, back, { tab: "watch", saved: action === "add" ? "watchAdded" : "watchRemoved" });
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    console.error(JSON.stringify({ level: "error", at: "record.watch", action, message: err.cause?.message ?? err.message }));
    return go(req, back, { tab: "watch", error: "generic" });
  }
}
