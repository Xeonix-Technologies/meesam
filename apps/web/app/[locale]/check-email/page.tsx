import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";

export default async function CheckEmail({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ email?: string; resent?: string }> }) {
  const { locale } = await params;
  const { email = "", resent } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  return (
    <AuthShell locale={locale} path="/check-email" title={t("checkEmail.title")}>
      <p>{t("checkEmail.body", { email })}</p>
      <form method="post" action="/api/auth/resend" className="inline-form">
        <input type="hidden" name="locale" value={locale} />
        <input type="hidden" name="email" value={email} />
        <button type="submit" className="button-secondary" disabled={!email}>{t("checkEmail.resend")}</button>
        {resent ? <span className="muted">✓</span> : null}
      </form>
    </AuthShell>
  );
}
