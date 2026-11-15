import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";

export default async function Forgot({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ sent?: string }> }) {
  const { locale } = await params;
  const { sent } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  return (
    <AuthShell locale={locale} path="/forgot-password" title={t("forgot.title")}>
      {sent ? <p className="notice">{t("forgot.sent")}</p> : <p>{t("forgot.body")}</p>}
      <form method="post" action="/api/auth/forgot" className="form">
        <input type="hidden" name="locale" value={locale} />
        <Field label={t("common.email")} name="email"><input id="email" name="email" type="email" required dir="ltr" autoComplete="email" /></Field>
        <div className="actions"><button type="submit" className="button">{t("forgot.submit")}</button></div>
      </form>
    </AuthShell>
  );
}
