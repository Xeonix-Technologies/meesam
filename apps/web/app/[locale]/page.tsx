import { Logo } from "@/components/Logo";
import Link from "next/link";
import { isLocale, translator, type Locale } from "@meesam/i18n";

export default async function Home({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const current: Locale = isLocale(locale) ? locale : "en";
  const other: Locale = current === "en" ? "ar" : "en";
  const t = translator(current);
  return (
    <main>
      <section className="card">
        <h1 className="brand"><Logo height={40} /><span className="ms-sr">{t("brand")}</span></h1>
        <p className="tagline">{t("tagline")}</p>
        <h2>{t("status.title")}</h2>
        <p>{t("status.body")}</p>
        <div className="registries">
          <strong>{t("registries.label")}:</strong> {t("registries.pilot")}
        </div>
        <div className="actions-row">
          <Link href={`/${current}/create-account`} className="button">{t("nav.createAccount")}</Link>
          <Link href={`/${current}/login`} className="button-secondary">{t("nav.login")}</Link>
        </div>
        <footer>
          <span>© {new Date().getFullYear()} {t("footer.company")} · {t("footer.rights")}</span>
          <Link href={`/${other}`} hrefLang={other}>{t("lang.switch")}</Link>
        </footer>
      </section>
    </main>
  );
}
