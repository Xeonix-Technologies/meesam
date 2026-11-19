import { cookies } from "next/headers";
import { feedStatus } from "@/lib/calendar";
import { getNotifyPrefs } from "@/lib/notifyPrefs";
import { appUrl } from "@/lib/mail";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { getAccountSettings } from "@/lib/account";
import { directoryListed } from "@/lib/appointments";
import { myTwoFactor, otpauthUri } from "@/lib/twofactor";
import { Field } from "@/components/Field";
import { COUNTRIES } from "@/components/countries";
import { MIN_PASSWORD_LENGTH } from "@/lib/password";

export const dynamic = "force-dynamic";

/** Account settings (Owner 3.1 / Agency 3.1): what the account is, who the signed-in person is, and the password. */
export default async function SettingsPage({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string; field?: string; saved?: string; setup?: string }> }) {
  const { locale } = await params;
  const { error, field, saved, setup } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const a = await getAccountSettings(session);
  if (!a) notFound();
  const listed = a.kind === "agency_office" ? await directoryListed(session) : false;
  const tf = await myTwoFactor(session);
  // calendar feed: the link is shown only right after it is made (the secret is not kept, only its hash)
  const cal = session.verificationStatus === "verified" ? await feedStatus(session) : null;
  const calToken = (await cookies()).get("ms_cal")?.value ?? null;
  const prefs = cal ? await getNotifyPrefs(session) : null;
  const calUrl = calToken ? `${appUrl()}/api/calendar/feed/${calToken}.ics` : null;
  const group = (x: string) => x.replace(/(.{4})/g, "$1 ").trim();
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

      <section className="card" id="twofactor">
        <h2>{t("settings.twofactor.title")}</h2>
        <p className="muted small">{tf.required && !tf.optIn && !tf.totp ? t("settings.twofactor.required") : tf.required ? t("settings.twofactor.on") : t("settings.twofactor.optional")}</p>
        {error === "totpCode" ? <p className="error" role="alert">{t("settings.twofactor.badCode")}</p> : null}
        <dl className="ms-kv">
          <dt>{t("settings.twofactor.email")}</dt><dd>{tf.required ? t("settings.twofactor.emailOn", { email: a.email }) : t("settings.twofactor.emailOff")}</dd>
          <dt>{t("settings.twofactor.app")}</dt><dd>{tf.totp ? t("settings.twofactor.appOn") : t("settings.twofactor.appOff")}</dd>
        </dl>
        {tf.totp ? (
          <form method="post" action="/api/account/twofactor" className="form">
            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="remove" />
            <div className="actions"><span className="muted small">{t("settings.twofactor.removeNote")}</span><button className="button-secondary" type="submit">{t("settings.twofactor.remove")}</button></div>
          </form>
        ) : setup && tf.pending ? (
          <form method="post" action="/api/account/twofactor" className="form">
            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="confirm" />
            <p>{t("settings.twofactor.step1")}</p>
            <div className="pass-code"><span className="ms-cap">{t("settings.twofactor.key")}</span><b className="num" dir="ltr">{group(tf.pending)}</b><a className="ms-link" href={otpauthUri(tf.pending, a.email)}>{t("settings.twofactor.openApp")}</a></div>
            <Field label={t("settings.twofactor.step2")} name="code"><input id="code" name="code" required inputMode="numeric" pattern="[0-9 ]{6,7}" maxLength={7} dir="ltr" autoComplete="one-time-code" /></Field>
            <div className="actions"><span /><button className="button" type="submit">{t("settings.twofactor.confirm")}</button></div>
          </form>
        ) : (
          <form method="post" action="/api/account/twofactor" className="form">
            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="begin" />
            <div className="actions"><span className="muted small">{t("settings.twofactor.appWhy")}</span><button className="button" type="submit">{t("settings.twofactor.setup")}</button></div>
          </form>
        )}
        {!tf.totp && (!tf.required || tf.optIn) ? (
          <form method="post" action="/api/account/twofactor" className="form">
            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="opt" /><input type="hidden" name="on" value={tf.optIn ? "0" : "1"} />
            <div className="actions"><span /><button className="button-secondary" type="submit">{tf.optIn ? t("settings.twofactor.optOff") : t("settings.twofactor.optOn")}</button></div>
          </form>
        ) : null}
      </section>

      {prefs ? (
      <section className="card" id="notifications">
        <h2>{t("settings.notify.title")}</h2>
        <p className="muted small">{t("settings.notify.sub")}</p>
        <form method="post" action="/api/account/notifications" className="form">
          <input type="hidden" name="locale" value={locale} />
          <p><b>{t("settings.notify.critical")}</b><br /><span className="muted small">{t("settings.notify.criticalNote")}</span></p>
          <fieldset className="ms-field"><legend className="ms-field__l">{t("settings.notify.important")}</legend>
            <label className="check"><input type="radio" name="important" value="now" defaultChecked={!prefs.important_digest} /> {t("settings.notify.importantNow")}</label>
            <label className="check"><input type="radio" name="important" value="digest" defaultChecked={prefs.important_digest} /> {t("settings.notify.importantDigest")}</label>
          </fieldset>
          <label className="check"><input type="checkbox" name="routine" value="1" defaultChecked={prefs.routine_digest} /> {t("settings.notify.routine")}</label>
          <div className="actions"><span className="muted small">{t("settings.notify.when")}</span><button className="button" type="submit">{t("common.save")}</button></div>
        </form>
      </section>
      ) : null}

      {cal ? (
      <section className="card" id="calendar">
        <h2>{t("settings.calendar.title")}</h2>
        <p className="muted small">{t("settings.calendar.sub")}</p>
        {cal.created_at && calUrl ? (
          <>
            <p>{t("settings.calendar.linkOnce")}</p>
            <div className="pass-code"><b className="num" dir="ltr" style={{ wordBreak: "break-all" }}>{calUrl}</b></div>
            <p className="muted small">{t("settings.calendar.how")}</p>
            <p><a className="ms-link" href={calUrl.replace(/^https?:/, "webcal:")}>{t("settings.calendar.open")}</a></p>
          </>
        ) : cal.created_at ? <p>{t("settings.calendar.on", { date: formatDate(cal.created_at, locale) })}{cal.last_read_at ? ` ${t("settings.calendar.lastRead", { date: formatDate(cal.last_read_at, locale) })}` : ""}</p> : null}
        <form method="post" action="/api/account/calendar" className="form">
          <input type="hidden" name="locale" value={locale} />
          <div className="actions">
            {cal.created_at ? <button className="button-secondary" type="submit" name="action" value="off">{t("settings.calendar.off")}</button> : <span />}
            <button className={cal.created_at ? "button-secondary" : "button"} type="submit" name="action" value="on">{t(cal.created_at ? "settings.calendar.replace" : "settings.calendar.create")}</button>
          </div>
        </form>
      </section>
      ) : null}

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
