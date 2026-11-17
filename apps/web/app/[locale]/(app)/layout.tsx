import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import type { ReactNode } from "react";
import { isLocale, pickText, translator, type Locale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { NavLink } from "@/components/NavLink";
import { Logo } from "@/components/Logo";

export const dynamic = "force-dynamic";

/** Signed-in frame. Login first; nothing is reachable before authentication (Ruled). */
export default async function AppLayout({ children, params }: { children: ReactNode; params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const t = translator(locale);
  const other: Locale = locale === "en" ? "ar" : "en";
  const home = session.verificationStatus === "verified" ? "dashboard" : "verification";
  const isAdmin = session.role === "company_admin" || session.role === "agency_admin";
  const acc = pickText(session.accountName, locale);
  const nav: Array<[string, string]> = [["dashboard", t("nav.dashboard")], ["records", t("portfolio.title")]];
  return (
    <div className="app ms-shell">
      <header className="ms-top">
        <Link href={`/${locale}`} className="ms-word brand-link" aria-label={t("brand")}><Logo tone="reversed" height={22} /></Link>
        <span className="ms-top__sp" />
        <div className="app-account">
          {/* Owner (individual): the person's name opens the account. Company or agency: the account name opens the
              account details (administrators only); the person's name opens their own details. */}
          {session.accountKind === "owner_individual" ? (
            <Link href={`/${locale}/settings`} className="ms-acct__btn" title={t("settings.title")}>
              <span className="ms-acct__mono" aria-hidden="true">{session.userName.slice(0, 1)}</span>
              <span className="ms-acct__txt"><span className="ms-acct__name">{session.userName}</span></span>
            </Link>
          ) : (
            <span className="ms-acct__btn">
              {session.logoKey ? <img className="ms-acct__logo" src="/api/account/logo" alt="" /> : <span className="ms-acct__mono" aria-hidden="true">{(acc || session.userName).slice(0, 1)}</span>}
              <span className="ms-acct__txt">
                <span className="ms-acct__name">{isAdmin ? <Link href={`/${locale}/settings`} title={t("settings.account")}>{acc}</Link> : acc}</span>
                <span className="ms-acct__sub"><Link href={`/${locale}/settings#you`}>{session.userName}</Link></span>
              </span>
            </span>
          )}
          <Link href={`/${other}/${home}`} hrefLang={other} lang={other} className="ms-langbtn">{t("lang.switch")}</Link>
          <form method="post" action="/api/auth/logout">
            <input type="hidden" name="locale" value={locale} />
            <button type="submit" className="ms-btn ms-btn--quiet">{t("nav.logout")}</button>
          </form>
        </div>
      </header>
      <nav className="ms-nav" aria-label={t("nav.dashboard")}>
        {nav.map(([slug, label]) => <NavLink key={slug} href={`/${locale}/${slug}`}>{label}</NavLink>)}
      </nav>
      <main className="ms-main app-main">{children}</main>
    </div>
  );
}
