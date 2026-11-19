import Link from "next/link";
import type { ReactNode } from "react";
import { translator, type Locale } from "@meesam/i18n";
import { Logo } from "./Logo";
import { LegalLinks } from "./LegalLinks";
import { CookieNotice } from "./CookieNotice";
import { getSession } from "@/lib/session";

/**
 * Public-page frame: brand, language switch that keeps the page, one card. A signed-in visitor (for example
 * reading a legal page from inside the app) sees their name and the way back, not "Log in".
 */
export async function AuthShell({ locale, path, title, children, wide = false }: { locale: Locale; path: string; title?: string; children: ReactNode; wide?: boolean }) {
  const t = translator(locale);
  const other: Locale = locale === "en" ? "ar" : "en";
  const session = await getSession().catch(() => null);
  return (
    <main className="auth">
      <header className="auth-header">
        <Link href={`/${locale}`} className="brand-link" aria-label={t("brand")}><Logo height={22} /></Link>
        <nav>
          {session ? (
            <><span className="muted">{session.userName}</span><Link href={`/${locale}/dashboard`}>{t("nav.backToApp")}</Link></>
          ) : <Link href={`/${locale}/login`}>{t("nav.login")}</Link>}
          <Link href={`/${other}${path}`} hrefLang={other} lang={other}>{t("lang.switch")}</Link>
        </nav>
      </header>
      <section className={wide ? "card card-wide" : "card"}>
        {title ? <h1>{title}</h1> : null}
        {children}
      </section>
      <footer className="auth-footer"><LegalLinks locale={locale} /><div>© {new Date().getFullYear()} {t("footer.company")} · {t("footer.rights")}</div></footer>
      <CookieNotice text={t("legal.cookieBar")} more={t("legal.short.cookies")} ok={t("legal.cookieOk")} href={`/${locale}/legal/cookies`} />
    </main>
  );
}
