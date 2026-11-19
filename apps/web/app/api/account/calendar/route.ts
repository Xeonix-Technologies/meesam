import { isLocale } from "@meesam/i18n";
import { feedOff, resetFeed } from "@/lib/calendar";
import { go, requireVerified } from "@/lib/guard";

export const runtime = "nodejs";

/** The signed-in user's calendar feed: switch on, replace the link, or switch off. The link is shown once, right after it is made. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale, { ownDetails: true });
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  const action = String(form.get("action") ?? "");
  try {
    if (action === "off") { await feedOff(auth.session); return go(req, back, { saved: "calendarOff" }, "calendar"); }
    if (action === "on") {
      const token = await resetFeed(auth.session);
      const res = go(req, back, { saved: "calendarOn" }, "calendar");
      // shown once on the settings page, then gone: only the hash is kept
      res.cookies.set("ms_cal", token, { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: 600 });
      return res;
    }
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "account.calendar", message: (e as Error).message }));
    return go(req, back, { error: "calendar" }, "calendar");
  }
  return go(req, back);
}
