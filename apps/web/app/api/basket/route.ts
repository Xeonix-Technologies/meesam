import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { checkoutBasket, requestActivation, withdrawActivation } from "@/lib/basket";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Activation and the basket (Founder ruling 27 Nov 2026; migration 0104): ask for activation of one trademark or
 * of every ready one, take one out of the basket, or check the basket out. The database decides who may, which
 * records qualify, and whether checkout is open; it audits each change.
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const action = String(form.get("action") ?? "");
  const id = String(form.get("record_id") ?? "");
  const basketPage = `/${locale}/basket`;
  // from a trademark's own page the answer returns there; from anywhere else, to the basket
  const back = String(form.get("from") ?? "") === "record" && UUID.test(id) ? `/${locale}/records/${id}` : basketPage;
  try {
    if (action === "request" && UUID.test(id)) {
      const n = await requestActivation(auth.session, id);
      return go(req, back, n ? { saved: "inBasket" } : { error: "notReady" });
    }
    if (action === "request_ready") {
      const n = await requestActivation(auth.session, null);
      return go(req, basketPage, n ? { added: String(n) } : { error: "noneReady" });
    }
    if (action === "withdraw" && UUID.test(id)) {
      await withdrawActivation(auth.session, id);
      return go(req, back, { saved: "takenOut" });
    }
    if (action === "checkout") {
      const n = await checkoutBasket(auth.session);
      return go(req, basketPage, n ? { activated: String(n) } : { error: "empty" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    const code = err.cause?.code;
    console.error(JSON.stringify({ level: "error", at: "basket", action, message: err.cause?.message ?? err.message }));
    // 42501: a Viewer, or an account that does not hold the record; 0A000: a price is due and payment is not connected
    return go(req, back, { error: code === "42501" ? "notAllowed" : code === "0A000" ? "paymentClosed" : "generic" });
  }
  return go(req, back);
}
