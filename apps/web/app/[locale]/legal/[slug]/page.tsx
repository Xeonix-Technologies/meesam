import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { COOKIES_IN_USE, LEGAL_DOCS, LEGAL_VERSION, LegalBody, isLegalSlug } from "@/lib/legal";

/** A legal text as published: Terms of Use, Privacy Policy, Cookie Notice, Acceptable Use Policy, AI and Watch Notice. No login needed. */
export default async function LegalPage({ params }: { params: Promise<{ locale: string; slug: string }> }) {
  const { locale, slug } = await params;
  if (!isLocale(locale) || !isLegalSlug(slug)) notFound();
  const t = translator(locale);
  const doc = LEGAL_DOCS[slug];
  return (
    <AuthShell locale={locale} path={`/legal/${slug}`} title={t(`legal.titles.${slug}`)} wide>
      {/* the documents are drafts until the Founder and the lawyer release them; the page says so in plain words */}
      <div className="ms-note ms-note--warn" role="note"><div><div className="ms-note__t">{t("legal.draftTitle")}</div><div>{t("legal.draftBody", { version: LEGAL_VERSION, date: doc.dated })}</div></div></div>
      {locale !== "en" ? <p className="muted small">{t("legal.englishOnly")}</p> : null}
      <article className="legal" lang="en" dir="ltr">
        <LegalBody body={doc.body} />
      </article>
      {slug === "cookies" ? (
        <section id="settings" className="legal-extra">
          <h2>{t("legal.cookies.title")}</h2>
          <p>{t("legal.cookies.lead")}</p>
          <div className="legal-table"><table>
            <thead><tr><th scope="col">{t("legal.cookies.name")}</th><th scope="col">{t("legal.cookies.purpose")}</th><th scope="col">{t("legal.cookies.life")}</th></tr></thead>
            <tbody>{COOKIES_IN_USE.map((c) => <tr key={c.name}><td className="num" dir="ltr">{c.name}</td><td>{t(`legal.cookies.purposes.${c.purpose}`)}</td><td className="num">{c.life}</td></tr>)}</tbody>
          </table></div>
          <p className="muted small">{t("legal.cookies.none")}</p>
        </section>
      ) : null}
    </AuthShell>
  );
}
