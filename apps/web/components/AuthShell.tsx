import Link from "next/link";
import type { ReactNode } from "react";
import { translator, type Locale } from "@meesam/i18n";

/** Public-page frame: brand, language switch that keeps the page, one card. */
export function AuthShell({ locale, path, title, children, wide = false }: { locale: Locale; path: string; title?: string; children: ReactNode; wide?: boolean }) {
  const t = translator(locale);
  const other: Locale = locale === "en" ? "ar" : "en";
  return (
    <main className="auth">
      <header className="auth-header">
        <Link href={`/${locale}`} className="brand-link">{t("brand")}</Link>
        <nav>
          <Link href={`/${locale}/login`}>{t("nav.login")}</Link>
          <Link href={`/${other}${path}`} hrefLang={other} lang={other}>{t("lang.switch")}</Link>
        </nav>
      </header>
      <section className={wide ? "card card-wide" : "card"}>
        {title ? <h1>{title}</h1> : null}
        {children}
      </section>
      <footer className="auth-footer">© {new Date().getFullYear()} {t("footer.company")} · {t("footer.rights")}</footer>
    </main>
  );
}
