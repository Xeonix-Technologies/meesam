import { cookies } from "next/headers";
import type { NextResponse } from "next/server";
import { redirectTo } from "./auth";
import { passAddressee } from "./pass";
import { askTwoStep } from "./twofactor";

/**
 * Where a user goes once signed in (after the password alone, or after the second factor): back to an owner
 * pass that is waiting for this address, else the dashboard, or the verification page for an account under review.
 */
export async function afterLogin(req: Request, u: { userId: string; email: string; locale: string; verification_status: string }): Promise<NextResponse> {
  const locale = u.locale === "ar" ? "ar" : "en";
  const jar = await cookies();
  const held = jar.get("ms_pass_hold")?.value;
  if (held) {
    // only the person the pass is for is taken back to it: a pass e-mailed to one address does not follow
    // another account that happens to log in from the same browser (Founder report 18 Nov 2026)
    const forWhom = await passAddressee(held, u.email).catch(() => null);
    if (forWhom === "named" || forWhom === "open") return redirectTo(req, `/${locale}/pass`, { code: held });
    if (forWhom === null) jar.delete("ms_pass_hold");
  }
  // Founder ruling 23 Nov 2026: a login that has not chosen yet is asked once, after signing in, whether and how to
  // use two-step sign-in. A failure to read the flag never stands between a person and their account.
  if (u.verification_status === "verified" && (await askTwoStep(u.userId).catch((e) => { console.error(JSON.stringify({ level: "error", at: "login.two-step.ask", message: `the two-step question could not be read: ${(e as Error).message}`.slice(0, 200) })); return false; }))) return redirectTo(req, `/${locale}/two-step`);
  return redirectTo(req, `/${locale}/${u.verification_status === "verified" ? "dashboard" : "verification"}`);
}
