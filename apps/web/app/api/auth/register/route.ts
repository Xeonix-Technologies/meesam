import { sql } from "drizzle-orm";
import { withinLimits } from "@/lib/auth";
import { requestMeta } from "@/lib/session";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { EMAIL_RE, issueToken, localeOf, redirectTo, text } from "@/lib/auth";
import { hashPassword, MIN_PASSWORD_LENGTH } from "@/lib/password";
import { sendVerifyMail } from "@/lib/mail";
import { recordConsent } from "@/lib/consent";
import { signupOpen } from "@/lib/signup";

export const runtime = "nodejs";

const KINDS = { individual: "owner_individual", company: "owner_company", agency: "agency_office" } as const;
type KindKey = keyof typeof KINDS;

/** Create account (Owner 3.1 / Agency 3.1). Fields per kind; the account is inactive until verified. */
export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const kindKey = text(form, "kind") as KindKey;
  const back = `/${locale}/create-account/${kindKey}`;
  // sign-up closed in this environment (SIGNUP): nothing is read or stored; the page says so
  if (!signupOpen() || !(kindKey in KINDS)) return redirectTo(req, `/${locale}/create-account`);

  // On any error the user gets the form back with what they typed (never the passwords) and the field named.
  const keep: Record<string, string> = {};
  for (const [k, v] of form.entries()) {
    if (typeof v !== "string" || k.startsWith("password") || k === "kind" || k === "locale" || k === "consent") continue;
    keep[k] = k in keep ? `${keep[k]},${v}` : v.slice(0, 200);   // repeated keys (checkboxes) join with commas
  }
  const fail = (error: string, field: string) => redirectTo(req, back, { ...keep, error, field });

  // at most 6 accounts an hour from one network address (sign-in limits review, 21 Nov 2026)
  const meta = await requestMeta();
  if (meta.ip && !(await withinLimits([[`register:ip:${meta.ip}`, 6, 60]]))) return redirectTo(req, back, { ...keep, error: "throttled" });

  const email = text(form, "email").toLowerCase();
  const password = String(form.get("password") ?? "");
  const password2 = String(form.get("password2") ?? "");
  // an individual owner is one person: the name is asked once and is also the user's name
  const userName = kindKey === "individual" ? (text(form, "name_en") || text(form, "name_ar")) : text(form, "user_name");
  const country = text(form, "country", 2).toUpperCase();
  const uiLocale = text(form, "ui_locale") === "ar" ? "ar" : "en";

  if (!EMAIL_RE.test(email)) return fail("email", "email");
  if (password.length < MIN_PASSWORD_LENGTH) return fail("password", "password");
  if (password !== password2) return fail("passwordMatch", "password2");
  if (!userName) return fail("required", kindKey === "individual" ? "name_en" : "user_name");
  if (!/^[A-Z]{2}$/.test(country)) return fail("required", "country");
  // no account without the consent: the box is required in the form and checked again here
  if (text(form, "consent") !== "1") return fail("consent", "consent");

  const name: Record<string, string> = {};
  const payload: Record<string, unknown> = { kind: KINDS[kindKey], country, contact: {}, user: { email, name: userName, locale: uiLocale } };

  if (kindKey === "individual") {
    const ar = text(form, "name_ar");
    const en = text(form, "name_en");
    if (!ar && !en) return fail("required", "name_en");
    if (ar) name.ar = ar;
    if (en) name.en = en;
    payload.contact = { mobile: text(form, "mobile", 40) };
  } else {
    const ar = text(form, "legal_name_ar");
    const en = text(form, "legal_name_en");
    const city = text(form, "city", 80);
    if (!ar && !en) return fail("required", "legal_name_en");
    if (!city) return fail("required", "city");
    if (ar) name.ar = ar;
    if (en) name.en = en;
    payload.city = city;
    payload.contact = { mobile: text(form, "mobile", 40) };
    if (kindKey === "company") {
      const ref = text(form, "registration_ref", 120);
      if (!ref) return fail("required", "registration_ref");
      payload.registration_ref = ref;
    } else {
      const licenceRef = text(form, "licence_ref", 120);
      const licenceRegistry = text(form, "licence_registry", 2).toUpperCase();
      if (!licenceRef) return fail("required", "licence_ref");
      if (!/^[A-Z]{2}$/.test(licenceRegistry)) return fail("required", "licence_registry");
      payload.licences = [{ registry_code: licenceRegistry, licence_ref: licenceRef }];
      payload.languages_served = form.getAll("languages_served").map(String).filter((v) => /^[a-z]{2}$/.test(v));
    }
  }
  payload.name = name;
  (payload.user as Record<string, unknown>).password_hash = await hashPassword(password);

  let userId: string;
  try {
    const rows = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.sp_register_account(${JSON.stringify(payload)}::jsonb)`))) as unknown as Array<{ account_id: string; user_id: string }>;
    userId = rows[0]!.user_id;
  } catch (err) {
    const code = (err as { cause?: { code?: string }; code?: string }).cause?.code ?? (err as { code?: string }).code;
    if (code === "23505") return fail("exists", "email");
    console.error(JSON.stringify({ level: "error", at: "auth.register", message: (err as Error).message }));
    return fail("generic", "");
  }

  try {
    await recordConsent(userId, "sign_up");
  } catch (err) {
    // the person did tick the box; a failed write must not lose the account, but it must be seen
    console.error(JSON.stringify({ level: "error", at: "auth.register.consent", message: (err as Error).message }));
  }
  const token = await issueToken(userId, "email_verify", "24 hours");
  try {
    await sendVerifyMail(email, userName, uiLocale, token);
  } catch {
    // the account exists; the user can ask for the link again from the check-e-mail page
  }
  return redirectTo(req, `/${locale}/check-email`, { email });
}
