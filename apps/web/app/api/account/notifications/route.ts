import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { setNotifyPrefs } from "@/lib/notifyPrefs";

export const runtime = "nodejs";

/** The signed-in user's own notification preferences. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale, { ownDetails: true });
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  try {
    await setNotifyPrefs(auth.session, { important_digest: form.get("important") === "digest", routine_digest: form.get("routine") === "1" });
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "account.notifications", message: (e as Error).message }));
    return go(req, back, { error: "notifications" }, "notifications");
  }
  return go(req, back, { saved: "notifications" }, "notifications");
}
