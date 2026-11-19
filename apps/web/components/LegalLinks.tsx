import Link from "next/link";
import { translator, type Locale } from "@meesam/i18n";

/** The legal links carried by every page footer (Home Page Content, Block 9; Cookie Notice 3.2 "Cookie settings" in the footer). */
export function LegalLinks({ locale }: { locale: Locale }) {
  const t = translator(locale);
  const item = (slug: string, hash = "") => <Link key={slug + hash} href={`/${locale}/legal/${slug}${hash}`}>{t(hash ? "legal.cookieSettings" : `legal.short.${slug}`)}</Link>;
  return <nav className="legal-links" aria-label={t("legal.nav")}>{item("terms")}{item("privacy")}{item("cookies")}{item("acceptable-use")}{item("ai-and-watch")}{item("cookies", "#settings")}</nav>;
}
