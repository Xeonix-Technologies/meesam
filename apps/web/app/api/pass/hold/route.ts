import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { publicBase } from "@/lib/guard";
import { destroySession } from "@/lib/session";

export const runtime = "nodejs";
const PASS_HOLD = "ms_pass_hold";

/**
 * Keeps an owner pass code while the person logs in, creates an account or switches account (item 39 (vii):
 * a pass may be redeemed during registration as well as after login). The code waits in a cookie only this
 * browser sends; after the next login the owner is taken back to the pass. `to=switch` also logs out the
 * account that is signed in (for example the agency that issued the pass, testing its own link).
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const code = String(form.get("code") ?? "").replace(/[^A-Za-z0-9-]/g, "").slice(0, 20);
  const to = String(form.get("to") ?? "login");
  if (to === "switch") await destroySession();
  const res = NextResponse.redirect(new URL(`/${locale}/${to === "register" ? "create-account" : "login"}`, publicBase(req)), 303);
  if (code) res.cookies.set(PASS_HOLD, code, { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: 7 * 24 * 3600 });
  return res;
}
