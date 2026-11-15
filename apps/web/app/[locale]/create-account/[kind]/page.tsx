import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";
import { COUNTRIES, LICENCE_REGISTRIES } from "@/components/countries";

const KINDS = ["individual", "company", "agency"] as const;
type Kind = (typeof KINDS)[number];

export default async function Register({ params, searchParams }: { params: Promise<{ locale: string; kind: string }>; searchParams: Promise<{ error?: string }> }) {
  const { locale, kind } = await params;
  const { error } = await searchParams;
  if (!isLocale(locale) || !(KINDS as readonly string[]).includes(kind)) notFound();
  const k = kind as Kind;
  const t = translator(locale);
  const name = (c: { en: string; ar: string }) => (locale === "ar" ? c.ar : c.en);

  return (
    <AuthShell locale={locale} path={`/create-account/${k}`} title={t(`register.${k}.title`)} wide>
      {error ? <p className="error" role="alert">{t(`register.errors.${error}`)}</p> : null}
      <form method="post" action="/api/auth/register" className="form">
        <input type="hidden" name="locale" value={locale} />
        <input type="hidden" name="kind" value={k} />

        {k === "individual" ? (
          <>
            <div className="grid-2">
              <Field label={t("common.nameAr")} name="name_ar" required={false}><input id="name_ar" name="name_ar" dir="rtl" lang="ar" /></Field>
              <Field label={t("common.nameEn")} name="name_en" required={false}><input id="name_en" name="name_en" dir="ltr" lang="en" /></Field>
            </div>
            <Field label={t("register.nationality")} name="country">
              <select id="country" name="country" required defaultValue="AE">{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{name(c)}</option>)}</select>
            </Field>
            <Field label={t("common.mobile")} name="mobile" required={false}><input id="mobile" name="mobile" type="tel" dir="ltr" inputMode="tel" /></Field>
          </>
        ) : (
          <>
            <div className="grid-2">
              <Field label={t(`register.${k}.legalNameAr`)} name="legal_name_ar" required={false}><input id="legal_name_ar" name="legal_name_ar" dir="rtl" lang="ar" /></Field>
              <Field label={t(`register.${k}.legalNameEn`)} name="legal_name_en" required={false}><input id="legal_name_en" name="legal_name_en" dir="ltr" lang="en" /></Field>
            </div>
            <div className="grid-2">
              <Field label={t("common.country")} name="country">
                <select id="country" name="country" required defaultValue="AE">{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{name(c)}</option>)}</select>
              </Field>
              <Field label={t("common.city")} name="city" />
            </div>
            {k === "company" ? (
              <Field label={t("register.company.registrationRef")} name="registration_ref" hint={t("register.uploadLater")} />
            ) : (
              <>
                <div className="grid-2">
                  <Field label={t("register.agency.licenceAt")} name="licence_registry">
                    <select id="licence_registry" name="licence_registry" required defaultValue="AE">{LICENCE_REGISTRIES.map((c) => <option key={c.code} value={c.code}>{name(c)}</option>)}</select>
                  </Field>
                  <Field label={t("register.agency.licence")} name="licence_ref" hint={t("register.uploadLater")} />
                </div>
                <fieldset className="field">
                  <legend className="field-label">{t("register.agency.languagesServed")}</legend>
                  <label className="check"><input type="checkbox" name="languages_served" value="ar" defaultChecked /> {t("common.arabic")}</label>
                  <label className="check"><input type="checkbox" name="languages_served" value="en" defaultChecked /> {t("common.english")}</label>
                </fieldset>
                <p className="muted">{t("register.agency.listingNote")}</p>
              </>
            )}
            <Field label={t("common.mobile")} name="mobile" required={false}><input id="mobile" name="mobile" type="tel" dir="ltr" inputMode="tel" /></Field>
            <h2 className="section-title">{t(`register.${k}.firstUser`)}</h2>
          </>
        )}

        <Field label={t("common.name")} name="user_name" />
        <Field label={t("common.email")} name="email"><input id="email" name="email" type="email" required dir="ltr" autoComplete="email" /></Field>
        <div className="grid-2">
          <Field label={t("common.password")} name="password" hint={t("register.passwordRule")}><input id="password" name="password" type="password" required minLength={10} autoComplete="new-password" /></Field>
          <Field label={t("common.passwordAgain")} name="password2"><input id="password2" name="password2" type="password" required minLength={10} autoComplete="new-password" /></Field>
        </div>
        <Field label={t("common.language")} name="ui_locale">
          <select id="ui_locale" name="ui_locale" defaultValue={locale}><option value="ar">{t("common.arabic")}</option><option value="en">{t("common.english")}</option></select>
        </Field>
        <p className="muted small">{t("register.legal")}</p>
        <div className="actions">
          <Link href={`/${locale}/create-account`} className="button-secondary">{t("common.back")}</Link>
          <button type="submit" className="button">{t("register.submit")}</button>
        </div>
      </form>
    </AuthShell>
  );
}
