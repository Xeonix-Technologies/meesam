import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { EMAIL_RE, issueToken, localeOf, redirectTo, text } from "@/lib/auth";
import { hashPassword, MIN_PASSWORD_LENGTH } from "@/lib/password";
import { sendVerifyMail } from "@/lib/mail";

export const runtime = "nodejs";

const KINDS = { individual: "owner_individual", company: "owner_company", agency: "agency_office" } as const;
type KindKey = keyof typeof KINDS;

/** Create account (Owner 3.1 / Agency 3.1). Fields per kind; the account is inactive until verified. */
export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const kindKey = text(form, "kind") as KindKey;
  const back = `/${locale}/create-account/${kindKey}`;
  if (!(kindKey in KINDS)) return redirectTo(req, `/${locale}/create-account`);

  const email = text(form, "email").toLowerCase();
  const password = String(form.get("password") ?? "");
  const password2 = String(form.get("password2") ?? "");
  const userName = text(form, "user_name");
  const country = text(form, "country", 2).toUpperCase();
  const uiLocale = text(form, "ui_locale") === "ar" ? "ar" : "en";

  if (!EMAIL_RE.test(email)) return redirectTo(req, back, { error: "email" });
  if (password.length < MIN_PASSWORD_LENGTH) return redirectTo(req, back, { error: "password" });
  if (password !== password2) return redirectTo(req, back, { error: "passwordMatch" });
  if (!userName || !/^[A-Z]{2}$/.test(country)) return redirectTo(req, back, { error: "required" });

  const name: Record<string, string> = {};
  const payload: Record<string, unknown> = { kind: KINDS[kindKey], country, contact: {}, user: { email, name: userName, locale: uiLocale } };

  if (kindKey === "individual") {
    const ar = text(form, "name_ar");
    const en = text(form, "name_en");
    if (!ar && !en) return redirectTo(req, back, { error: "required" });
    if (ar) name.ar = ar;
    if (en) name.en = en;
    payload.contact = { mobile: text(form, "mobile", 40) };
  } else {
    const ar = text(form, "legal_name_ar");
    const en = text(form, "legal_name_en");
    const city = text(form, "city", 80);
    if ((!ar && !en) || !city) return redirectTo(req, back, { error: "required" });
    if (ar) name.ar = ar;
    if (en) name.en = en;
    payload.city = city;
    payload.contact = { mobile: text(form, "mobile", 40) };
    if (kindKey === "company") {
      const ref = text(form, "registration_ref", 120);
      if (!ref) return redirectTo(req, back, { error: "required" });
      payload.registration_ref = ref;
    } else {
      const licenceRef = text(form, "licence_ref", 120);
      const licenceRegistry = text(form, "licence_registry", 2).toUpperCase();
      if (!licenceRef || !/^[A-Z]{2}$/.test(licenceRegistry)) return redirectTo(req, back, { error: "required" });
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
    if (code === "23505") return redirectTo(req, back, { error: "exists" });
    console.error(JSON.stringify({ level: "error", at: "auth.register", message: (err as Error).message }));
    return redirectTo(req, back, { error: "generic" });
  }

  const token = await issueToken(userId, "email_verify", "24 hours");
  try {
    await sendVerifyMail(email, userName, uiLocale, token);
  } catch {
    // the account exists; the user can ask for the link again from the check-e-mail page
  }
  return redirectTo(req, `/${locale}/check-email`, { email });
}
