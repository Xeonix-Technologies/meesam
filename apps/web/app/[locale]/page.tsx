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
        <h1 className="brand">{t("brand")}</h1>
        <p className="tagline">{t("tagline")}</p>
        <h2>{t("status.title")}</h2>
        <p>{t("status.body")}</p>
        <div className="registries">
          <strong>{t("registries.label")}:</strong> {t("registries.pilot")}
        </div>
        <footer>
          <span>© {new Date().getFullYear()} {t("footer.company")} · {t("footer.rights")}</span>
          <Link href={`/${other}`} hrefLang={other}>{t("lang.switch")}</Link>
        </footer>
      </section>
    </main>
  );
}
