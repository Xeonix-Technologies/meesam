import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { redeemPass } from "@/lib/pass";

export const runtime = "nodejs";

/** An owner redeems a pass: the record is attached to the owner's account and the issuing agency goes on managing it. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  // Not requireVerified: an owner account still waiting for review may redeem a pass the agency sent to its own
  // address, and is verified by doing so (migration 0017). The database function decides.
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  const auth = { session };
  const code = String(form.get("code") ?? "").trim().slice(0, 40);
  if (auth.session.accountKind === "agency_office") return go(req, `/${locale}/pass`, { code, error: "agency" });
  try {
    const recordId = await redeemPass(auth.session, code);
    const res = go(req, `/${locale}/records/${recordId}`, { saved: "passRedeemed" });
    res.cookies.delete("ms_pass_hold");
    return res;
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    if (!/invalid, used or expired/.test(err.cause?.message ?? err.message)) console.error(JSON.stringify({ level: "error", at: "pass.redeem", message: err.message, cause: err.cause?.message }));
    return go(req, `/${locale}/pass`, { error: "bad" });
  }
}
