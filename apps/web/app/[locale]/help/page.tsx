import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";

const QUESTIONS = ["what", "who", "fee", "deadlines", "watch", "watchLimits", "advice", "links", "data", "languages", "support"] as const;

/**
 * Help: a short page of questions (Founder ruling R11, 21 Nov 2026). Answers state what Meesam does and does not
 * do, in the words of the rules in force; they promise nothing beyond them. Human support covers technical and
 * payment matters only (rule 11).
 */
export default async function Help({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  return (
    <AuthShell locale={locale} path="/help" title={t("help.title")} wide>
      <p className="home-lead">{t("help.lead")}</p>
      <div className="help-list">
        {QUESTIONS.map((q) => (
          <details key={q} className="help-q"><summary>{t(`help.q.${q}.q`)}</summary><p>{t(`help.q.${q}.a`)}</p></details>
        ))}
      </div>
      <p>{t("help.more")} <Link href={`/${locale}/pricing`}>{t("pricing.title")}</Link> · <Link href={`/${locale}/feedback`}>{t("feedback.title")}</Link> · <a href="mailto:info@meesam.ae" dir="ltr">info@meesam.ae</a></p>
    </AuthShell>
  );
}
