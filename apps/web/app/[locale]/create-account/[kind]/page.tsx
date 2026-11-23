import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";
import { Consent } from "@/components/Consent";
import { COUNTRIES, LICENCE_REGISTRIES } from "@/components/countries";
import { signupOpen } from "@/lib/signup";
import { SignupClosed } from "@/components/SignupClosed";

export const dynamic = "force-dynamic";

const KINDS = ["individual", "company", "agency"] as const;
type Kind = (typeof KINDS)[number];

export default async function Register({ params, searchParams }: { params: Promise<{ locale: string; kind: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const { locale, kind } = await params;
  const q = await searchParams;
  const { error, field } = q;
  if (!isLocale(locale) || !(KINDS as readonly string[]).includes(kind)) notFound();
  const k = kind as Kind;
  if (!signupOpen()) return <SignupClosed locale={locale} path={`/create-account/${k}`} />;
  const t = translator(locale);
  const name = (c: { en: string; ar: string }) => (locale === "ar" ? c.ar : c.en);
  // after a failed submit the typed values come back in the query string (passwords never do)
  const v = (key: string) => q[key] ?? "";
  const err = (key: string) => (error && field === key ? t(`register.errors.${error}`) : undefined);
  const inv = (key: string) => (error && field === key ? true : undefined);
  const langs = q.languages_served === undefined ? ["ar", "en"] : q.languages_served.split(",");

  return (
    <AuthShell locale={locale} path={`/create-account/${k}`} title={t(`register.${k}.title`)} wide>
      {error && !field ? <p className="error" role="alert">{t(`register.errors.${error}`)}</p> : null}
      {error && field ? <p className="error" role="alert">{t("register.errors.fixField")}</p> : null}
      <form method="post" action="/api/auth/register" className="form">
        <input type="hidden" name="locale" value={locale} />
        <input type="hidden" name="kind" value={k} />

        {k === "individual" ? (
          <>
            <div className="grid-2">
              <Field label={t("common.nameAr")} name="name_ar" required={false}><input id="name_ar" name="name_ar" dir="rtl" lang="ar" defaultValue={v("name_ar")} aria-invalid={inv("name_en")} /></Field>
              <Field label={t("common.nameEn")} name="name_en" required={false} error={err("name_en")}><input id="name_en" name="name_en" dir="ltr" lang="en" defaultValue={v("name_en")} aria-invalid={inv("name_en")} /></Field>
            </div>
            <Field label={t("register.nationality")} name="country" error={err("country")}>
              <select id="country" name="country" required defaultValue={v("country") || "AE"} aria-invalid={inv("country")}>{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{name(c)}</option>)}</select>
            </Field>
            <Field label={t("common.mobile")} name="mobile" required={false}><input id="mobile" name="mobile" type="tel" dir="ltr" inputMode="tel" defaultValue={v("mobile")} /></Field>
          </>
        ) : (
          <>
            <div className="grid-2">
              <Field label={t(`register.${k}.legalNameAr`)} name="legal_name_ar" required={false}><input id="legal_name_ar" name="legal_name_ar" dir="rtl" lang="ar" defaultValue={v("legal_name_ar")} aria-invalid={inv("legal_name_en")} /></Field>
              <Field label={t(`register.${k}.legalNameEn`)} name="legal_name_en" required={false} error={err("legal_name_en")}><input id="legal_name_en" name="legal_name_en" dir="ltr" lang="en" defaultValue={v("legal_name_en")} aria-invalid={inv("legal_name_en")} /></Field>
            </div>
            <div className="grid-2">
              <Field label={t("common.country")} name="country" error={err("country")}>
                <select id="country" name="country" required defaultValue={v("country") || "AE"} aria-invalid={inv("country")}>{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{name(c)}</option>)}</select>
              </Field>
              <Field label={t("common.city")} name="city" defaultValue={v("city")} error={err("city")} />
            </div>
            {k === "company" ? (
              <Field label={t("register.company.registrationRef")} name="registration_ref" hint={t("register.uploadLater")} defaultValue={v("registration_ref")} error={err("registration_ref")} />
            ) : (
              <>
                <div className="grid-2">
                  <Field label={t("register.agency.licenceAt")} name="licence_registry">
                    <select id="licence_registry" name="licence_registry" required defaultValue={v("licence_registry") || "AE"}>{LICENCE_REGISTRIES.map((c) => <option key={c.code} value={c.code}>{name(c)}</option>)}</select>
                  </Field>
                  <Field label={t("register.agency.licence")} name="licence_ref" hint={t("register.uploadLater")} defaultValue={v("licence_ref")} error={err("licence_ref")} />
                </div>
                <fieldset className="field">
                  <legend className="field-label">{t("register.agency.languagesServed")}</legend>
                  <label className="check"><input type="checkbox" name="languages_served" value="ar" defaultChecked={langs.includes("ar")} /> {t("common.arabic")}</label>
                  <label className="check"><input type="checkbox" name="languages_served" value="en" defaultChecked={langs.includes("en")} /> {t("common.english")}</label>
                </fieldset>
                <p className="muted">{t("register.agency.listingNote")}</p>
              </>
            )}
            <Field label={t("common.mobile")} name="mobile" required={false}><input id="mobile" name="mobile" type="tel" dir="ltr" inputMode="tel" defaultValue={v("mobile")} /></Field>
            <h2 className="section-title">{t(`register.${k}.firstUser`)}</h2>
          </>
        )}

        {k === "individual" ? null : <Field label={t("common.name")} name="user_name" defaultValue={v("user_name")} error={err("user_name")} />}
        <Field label={t("common.email")} name="email" error={err("email")}><input id="email" name="email" type="email" required dir="ltr" autoComplete="email" defaultValue={v("email")} aria-invalid={inv("email")} /></Field>
        <div className="grid-2">
          <Field label={t("common.password")} name="password" hint={t("register.passwordRule")} error={err("password")}><input id="password" name="password" type="password" required minLength={10} autoComplete="new-password" aria-invalid={inv("password")} /></Field>
          <Field label={t("common.passwordAgain")} name="password2" error={err("password2")}><input id="password2" name="password2" type="password" required minLength={10} autoComplete="new-password" aria-invalid={inv("password2")} /></Field>
        </div>
        <Field label={t("common.language")} name="ui_locale">
          <select id="ui_locale" name="ui_locale" defaultValue={v("ui_locale") || locale}><option value="ar">{t("common.arabic")}</option><option value="en">{t("common.english")}</option></select>
        </Field>
        <Consent locale={locale} error={err("consent")} />
        <div className="actions">
          <Link href={`/${locale}/create-account`} className="button-secondary">{t("common.back")}</Link>
          <button type="submit" className="button">{t("register.submit")}</button>
        </div>
      </form>
    </AuthShell>
  );
}
