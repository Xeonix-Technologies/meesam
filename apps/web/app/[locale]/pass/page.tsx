import { notFound } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { getSession } from "@/lib/session";
import { passAddressee, passPreview } from "@/lib/pass";

export const dynamic = "force-dynamic";

/**
 * Owner pass (4.4 link 2; item 39 (vii)): the page a pass link opens. It shows what the code is for and, for a
 * signed-in verified owner, attaches the record on confirmation. Someone not signed in is sent to log in or
 * create an owner account first, then returns here (the link, or the code under Agencies).
 */
export default async function Pass({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ code?: string; error?: string }> }) {
  const { locale } = await params;
  const { code = "", error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const session = await getSession().catch(() => null);
  const pass = code ? await passPreview(code).catch(() => null) : null;
  const owner = session && session.accountKind !== "agency_office" ? session : null;
  // A pass the agency had sent to this owner's own address verifies the account on redemption (Founder ruling
  // 18 Nov 2026, migration 0017): no staff review. Any other pass needs an account already verified.
  const forWhom = pass && owner ? await passAddressee(code, owner.email).catch(() => null) : null;
  const byPass = owner && owner.verificationStatus === "pending_review" && forWhom === "named";
  const ready = owner && (owner.verificationStatus === "verified" || byPass) ? owner : null;
  return (
    <AuthShell locale={locale} path="/pass" title={t("pass.title")}>
      {error === "bad" || (code && !pass) ? <p className="error" role="alert">{t("pass.bad")}</p> : null}
      {error === "agency" || (session && !owner) ? <p className="error" role="alert">{t("pass.agency", { name: pickText(session?.accountName, locale), email: session?.email ?? "" })}</p> : null}
      {pass ? (
        <>
          <p className="muted">{t("pass.intro", { agency: pickText(pass.agency_name, locale) })}</p>
          <dl className="ms-kv">
            <dt>{t("pass.mark")}</dt><dd><b>{pickText(pass.mark_text, locale) || "—"}</b></dd>
            <dt>{t("pass.registry")}</dt><dd><span className="num">{pass.registry_code} {pass.number ?? ""}</span></dd>
            <dt>{t("pass.agencyLabel")}</dt><dd>{pickText(pass.agency_name, locale)}</dd>
            <dt>{t("pass.validUntil")}</dt><dd>{formatDate(String(pass.expires_at), locale)}</dd>
          </dl>
          {ready ? (
            <form method="post" action="/api/pass" className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="code" value={code} />
              {forWhom === "other" ? <p className="error" role="alert">{t("pass.otherAddress", { email: ready.email })}</p> : null}
              {byPass ? <p className="notice">{t("pass.verifies")}</p> : null}
              <p className="notice">{t("pass.confirm", { account: pickText(ready.accountName, locale) || ready.userName, email: ready.email, agency: pickText(pass.agency_name, locale) })}</p>
              <div className="actions"><a className="button-secondary" href={`/${locale}/dashboard`}>{t("pass.cancel")}</a><button type="submit" className="button">{t("pass.redeem")}</button></div>
            </form>
          ) : owner ? (
            <p className="notice">{t("pass.notVerified")}</p>
          ) : !session ? (
            <form method="post" action="/api/pass/hold" className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="code" value={code} />
              <p className="notice">{t("pass.signIn")}</p>
              <div className="actions"><button type="submit" name="to" value="register" className="button-secondary">{t("nav.createAccount")}</button><button type="submit" name="to" value="login" className="button">{t("nav.login")}</button></div>
            </form>
          ) : (
            <form method="post" action="/api/pass/hold" className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="code" value={code} />
              <p className="notice">{t("pass.switch")}</p>
              <div className="actions"><a className="button-secondary" href={`/${locale}/dashboard`}>{t("pass.stay")}</a><button type="submit" name="to" value="switch" className="button">{t("pass.switchButton")}</button></div>
            </form>
          )}
        </>
      ) : (
        <form method="get" action={`/${locale}/pass`} className="form">
          <label className="field"><span>{t("pass.code")}</span><input name="code" defaultValue={code} required dir="ltr" autoComplete="off" placeholder="XXXX-XXXX-XXXX" /></label>
          <div className="actions"><span /><button type="submit" className="button">{t("pass.check")}</button></div>
        </form>
      )}
    </AuthShell>
  );
}
