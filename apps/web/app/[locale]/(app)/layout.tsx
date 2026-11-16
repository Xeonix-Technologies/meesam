import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import type { ReactNode } from "react";
import { isLocale, pickText, translator, type Locale } from "@meesam/i18n";
import { getSession } from "@/lib/session";

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
  return (
    <div className="app">
      <header className="app-header">
        <Link href={`/${locale}/${home}`} className="brand-link">{t("brand")}</Link>
        <nav className="app-nav">
          <Link href={`/${locale}/dashboard`}>{t("nav.dashboard")}</Link>
          <Link href={`/${locale}/records`}>{t("portfolio.title")}</Link>
        </nav>
        <div className="app-account">
          {(() => {
            // Owner (individual): the person's name opens the account. Company or agency: the account name opens the
            // account details (administrators only); the person's name opens their own details.
            const isAdmin = session.role === "company_admin" || session.role === "agency_admin";
            const acc = pickText(session.accountName, locale);
            const me = <Link href={`/${locale}/settings#you`} className="muted">{session.userName}</Link>;
            if (session.accountKind === "owner_individual") return <Link href={`/${locale}/settings`} className="muted" title={t("settings.title")}>{session.userName}</Link>;
            return (
              <span className="muted">
                {isAdmin ? <Link href={`/${locale}/settings`} className="muted" title={t("settings.account")}>{acc}</Link> : acc}
                {" · "}{me}
              </span>
            );
          })()}
          <Link href={`/${other}/${home}`} hrefLang={other} lang={other}>{t("lang.switch")}</Link>
          <form method="post" action="/api/auth/logout">
            <input type="hidden" name="locale" value={locale} />
            <button type="submit" className="link-button">{t("nav.logout")}</button>
          </form>
        </div>
      </header>
      <main className="app-main">{children}</main>
    </div>
  );
}
