import Link from "next/link";
import { translator, type Locale } from "@meesam/i18n";

/** The links carried by every page footer: the legal texts, then Help, Feedback and Contact (Home Page Content, Block 9; Cookie Notice 3.2 "Cookie settings" in the footer). */
export function LegalLinks({ locale }: { locale: Locale }) {
  const t = translator(locale);
  const item = (slug: string, hash = "") => <Link key={slug + hash} href={`/${locale}/legal/${slug}${hash}`}>{t(hash ? "legal.cookieSettings" : `legal.short.${slug}`)}</Link>;
  return <nav className="legal-links" aria-label={t("legal.nav")}>{item("terms")}{item("privacy")}{item("cookies")}{item("acceptable-use")}{item("ai-and-watch")}{item("cookies", "#settings")}
    {/* Help, Feedback and Contact (Founder ruling R11, 21 Nov 2026) */}
    <Link href={`/${locale}/help`}>{t("help.title")}</Link><Link href={`/${locale}/feedback`}>{t("feedback.title")}</Link><a href="mailto:info@meesam.ae">{t("footer.contact")}</a></nav>;
}
