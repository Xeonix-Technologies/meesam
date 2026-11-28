import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { removeRecord } from "@/lib/records";

export const runtime = "nodejs";

/**
 * Removes a trademark that was never activated (Founder ruling 28 Nov 2026; migration 0110). The database decides:
 * the account's administrator only, a mark of this account only, never one that was activated or paid. The row and
 * its audit history are kept; the mark leaves every page and its number is free again.
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  // the tick box is the confirmation: without it nothing is removed
  if (form.get("confirm") !== "1") return go(req, back, { error: "removeConfirm" });
  try {
    await removeRecord(auth.session, id);
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    const code = err.cause?.code;
    console.error(JSON.stringify({ level: "error", at: "record.remove", record: id, code: code ?? null, message: err.cause?.message ?? err.message }));
    return go(req, back, { error: code === "42501" ? "removeAdmin" : code === "55000" ? "removeActive" : "generic" });
  }
  return go(req, `/${locale}/records`, { saved: "removed" });
}
