import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { redeemPass } from "@/lib/pass";

export const runtime = "nodejs";

/** An owner redeems a pass: the record is attached to the owner's account and the issuing agency goes on managing it. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const code = String(form.get("code") ?? "").trim().slice(0, 40);
  if (auth.session.accountKind === "agency_office") return go(req, `/${locale}/pass`, { code, error: "agency" });
  try {
    const recordId = await redeemPass(auth.session, code);
    return go(req, `/${locale}/records/${recordId}`, { saved: "passRedeemed" });
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    if (!/invalid, used or expired/.test(err.cause?.message ?? err.message)) console.error(JSON.stringify({ level: "error", at: "pass.redeem", message: err.message, cause: err.cause?.message }));
    return go(req, `/${locale}/pass`, { error: "bad" });
  }
}
