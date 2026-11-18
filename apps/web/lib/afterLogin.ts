import { cookies } from "next/headers";
import type { NextResponse } from "next/server";
import { redirectTo } from "./auth";
import { passAddressee } from "./pass";

/**
 * Where a user goes once signed in (after the password alone, or after the second factor): back to an owner
 * pass that is waiting for this address, else the dashboard, or the verification page for an account under review.
 */
export async function afterLogin(req: Request, u: { email: string; locale: string; verification_status: string }): Promise<NextResponse> {
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
  return redirectTo(req, `/${locale}/${u.verification_status === "verified" ? "dashboard" : "verification"}`);
}
