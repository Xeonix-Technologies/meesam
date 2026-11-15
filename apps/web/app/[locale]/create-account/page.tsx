import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";

/** Create account → "Who are you?" (Owner 3.1 / Agency 3.1). */
export default async function WhoAreYou({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const kinds = ["individual", "company", "agency"] as const;
  return (
    <AuthShell locale={locale} path="/create-account" title={t("who.title")} wide>
      <p className="lead">{t("who.lead")}</p>
      <div className="choices">
        {kinds.map((k) => (
          <Link key={k} href={`/${locale}/create-account/${k}`} className="choice">
            <strong>{t(`who.${k}.title`)}</strong>
            <span>{t(`who.${k}.body`)}</span>
          </Link>
        ))}
      </div>
      <p className="muted">{t("who.haveAccount")} <Link href={`/${locale}/login`}>{t("nav.login")}</Link></p>
    </AuthShell>
  );
}
