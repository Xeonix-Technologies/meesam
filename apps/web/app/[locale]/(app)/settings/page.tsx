import { notFound, redirect } from "next/navigation";
import { isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { getAccountSettings } from "@/lib/account";
import { directoryListed } from "@/lib/appointments";
import { Field } from "@/components/Field";
import { COUNTRIES } from "@/components/countries";
import { MIN_PASSWORD_LENGTH } from "@/lib/password";

export const dynamic = "force-dynamic";

/** Account settings (Owner 3.1 / Agency 3.1): what the account is, who the signed-in person is, and the password. */
export default async function SettingsPage({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string; field?: string; saved?: string }> }) {
  const { locale } = await params;
  const { error, field, saved } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const a = await getAccountSettings(session);
  if (!a) notFound();
  const listed = a.kind === "agency_office" ? await directoryListed(session) : false;
  const t = translator(locale);
  const err = (f: string) => (error && field === f ? t(`settings.errors.${error}`) : undefined);
  const isCompany = a.kind !== "owner_individual";
  const canEditAccount = a.role === "company_admin" || a.role === "agency_admin";
  return (
    <div className="stack">
      <h1>{t("settings.title")}</h1>
      {saved ? <p className="success" role="status">{t(`settings.saved.${saved}`)}</p> : null}
      {error && !field ? <p className="error" role="alert">{t(`settings.errors.${error}`)}</p> : null}

      {canEditAccount ? <section className="card">
        <h2>{t("settings.account")}</h2>
        <p className="muted small">{t(`settings.kinds.${a.kind}`)} · {t(`verification.${a.verification_status}.label`)} · {t("settings.accountNote")}</p>
        <form method="post" action="/api/account/profile" className="form">
          <input type="hidden" name="locale" value={locale} />
          <div className="grid-2">
            <Field label={isCompany ? t("settings.legalNameAr") : t("settings.nameAr")} name="name_ar" required={false}><input id="name_ar" name="name_ar" dir="rtl" lang="ar" defaultValue={a.name.ar ?? ""} /></Field>
            <Field label={isCompany ? t("settings.legalNameEn") : t("settings.nameEn")} name="name_en" required={false} error={err("name_en")}><input id="name_en" name="name_en" dir="ltr" lang="en" defaultValue={a.name.en ?? ""} /></Field>
            <Field label={t("settings.country")} name="country" error={err("country")}>
              <select id="country" name="country" defaultValue={a.country}>{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{locale === "ar" ? c.ar : c.en}</option>)}</select>
            </Field>
            <Field label={t("settings.city")} name="city" required={false}><input id="city" name="city" defaultValue={a.city ?? ""} /></Field>
            <Field label={t("settings.mobile")} name="mobile" required={false}><input id="mobile" name="mobile" dir="ltr" inputMode="tel" defaultValue={a.contact?.mobile ?? ""} /></Field>
            <Field label={t("settings.phone")} name="phone" required={false}><input id="phone" name="phone" dir="ltr" inputMode="tel" defaultValue={a.contact?.phone ?? ""} /></Field>
            <Field label={t("settings.website")} name="website" required={false}><input id="website" name="website" dir="ltr" inputMode="url" defaultValue={a.contact?.website ?? ""} /></Field>
            <Field label={t("settings.address")} name="address" required={false}><input id="address" name="address" defaultValue={a.contact?.address ?? ""} /></Field>
          </div>
          <div className="logo-row">
            <div className="logo-box">{a.logo_key ? <img src="/api/account/logo" alt="" /> : <span className="muted small">{t("settings.noLogo")}</span>}</div>
            <div className="small muted">{t("settings.logoWhy")}</div>
          </div>
          {isCompany ? <p className="muted small">{t("settings.registrationRef")}: {a.registration_ref ?? "—"}{a.licence_no ? ` · ${t("settings.licenceNo")}: ${a.licence_no}` : ""} — {t("settings.fixedNote")}</p> : null}
          <div className="actions"><span /><button className="button" type="submit">{t("common.save")}</button></div>
        </form>
        <form method="post" action="/api/account/logo" encType="multipart/form-data" className="form upload-form">
          <input type="hidden" name="locale" value={locale} />
          <div className="grid-2">
            <Field label={a.logo_key ? t("settings.replaceLogo") : t("settings.uploadLogo")} name="logo" required={false} error={err("logo")} hint={t("settings.logoHint")}><input id="logo" name="file" type="file" accept=".png,.jpg,.jpeg,.webp" /></Field>
          </div>
          <div className="actions">
            {a.logo_key ? <button className="link-button" type="submit" name="remove" value="1" formNoValidate>{t("settings.removeLogo")}</button> : <span />}
            <button className="button-secondary" type="submit">{t("intake.documents.upload")}</button>
          </div>
        </form>
      </section> : null}

      {a.role === "agency_admin" && a.kind === "agency_office" ? <section className="card" id="directory">
        <h2>{t("settings.directory.title")}</h2>
        <p className="muted small">{t("settings.directory.why")}</p>
        <form method="post" action="/api/account/directory" className="form">
          <input type="hidden" name="locale" value={locale} />
          <div className="radio-row">
            <label className="check"><input type="radio" name="listed" value="yes" defaultChecked={listed} /> {t("settings.directory.yes")}</label>
            <label className="check"><input type="radio" name="listed" value="no" defaultChecked={!listed} /> {t("settings.directory.no")}</label>
          </div>
          <div className="actions"><span /><button className="button" type="submit">{t("common.save")}</button></div>
        </form>
      </section> : null}

      <section className="card" id="you">
        <h2>{t("settings.you")}</h2>
        <form method="post" action="/api/account/user" className="form">
          <input type="hidden" name="locale" value={locale} />
          <div className="grid-2">
            <Field label={t("settings.userName")} name="user_name" error={err("user_name")}><input id="user_name" name="user_name" defaultValue={a.user_name} /></Field>
            <Field label={t("settings.email")} name="email" required={false} hint={t("settings.emailNote")}><input id="email" name="email" dir="ltr" defaultValue={a.email} disabled /></Field>
            <Field label={t("settings.language")} name="user_locale" required={false}>
              <select id="user_locale" name="user_locale" defaultValue={a.locale}><option value="en">English</option><option value="ar">العربية</option></select>
            </Field>
          </div>
          <div className="actions"><span /><button className="button" type="submit">{t("common.save")}</button></div>
        </form>
      </section>

      <section className="card">
        <h2>{t("settings.password")}</h2>
        <form method="post" action="/api/account/password" className="form">
          <input type="hidden" name="locale" value={locale} />
          <div className="grid-2">
            <Field label={t("settings.currentPassword")} name="current_password" error={err("current_password")}><input id="current_password" name="current_password" type="password" autoComplete="current-password" required /></Field>
            <span />
            <Field label={t("settings.newPassword")} name="new_password" error={err("new_password")} hint={t("settings.passwordHint", { n: MIN_PASSWORD_LENGTH })}><input id="new_password" name="new_password" type="password" autoComplete="new-password" minLength={MIN_PASSWORD_LENGTH} required /></Field>
            <Field label={t("settings.confirmPassword")} name="confirm_password" error={err("confirm_password")}><input id="confirm_password" name="confirm_password" type="password" autoComplete="new-password" minLength={MIN_PASSWORD_LENGTH} required /></Field>
          </div>
          <div className="actions"><span className="muted small">{t("settings.passwordNote")}</span><button className="button" type="submit">{t("settings.changePassword")}</button></div>
        </form>
      </section>
    </div>
  );
}
