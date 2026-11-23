import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { beginTotp, confirmTotp, markAsked, newSecret, removeTotp, setOptIn } from "@/lib/twofactor";

export const runtime = "nodejs";

/** The signed-in user's own two-step sign-in: set up or remove the authenticator app, or switch the e-mail code on where it is optional. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale, { ownDetails: true });
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  const action = String(form.get("action") ?? "");
  // the answer to the question put once after signing in (Founder ruling 23 Nov 2026): by e-mail, by app, or not now
  if (action === "choose") {
    const how = String(form.get("how") ?? "");
    await markAsked(auth.session);
    const home = `/${locale}/${auth.session.verificationStatus === "verified" ? "dashboard" : "verification"}`;
    if (how === "app") { await beginTotp(auth.session, newSecret()); return go(req, back, { setup: "1" }, "twofactor"); }
    // staff logins have no switch: their second step is always on, by e-mail until an app is set up
    if (how === "email" && !auth.session.isStaff) await setOptIn(auth.session, true);
    return go(req, home, how === "email" ? { saved: "twofactor" } : {});
  }
  if (action === "begin") { await beginTotp(auth.session, newSecret()); return go(req, `${back}`, { setup: "1" }, "twofactor"); }
  if (action === "confirm") {
    const ok = await confirmTotp(auth.session, String(form.get("code") ?? ""));
    return ok ? go(req, back, { saved: "totp" }, "twofactor") : go(req, back, { setup: "1", error: "totpCode" }, "twofactor");
  }
  if (action === "remove") { await removeTotp(auth.session); return go(req, back, { saved: "totpRemoved" }, "twofactor"); }
  if (action === "opt") {
    await setOptIn(auth.session, form.get("on") === "1");
    return go(req, back, { saved: "twofactor" }, "twofactor");
  }
  return go(req, back);
}
