import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";
import { getSession } from "@/lib/session";

export const dynamic = "force-dynamic";

export default async function Login({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string; email?: string; reset?: string }> }) {
  const { locale } = await params;
  const { error, email = "", reset } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (session) redirect(`/${locale}/${session.verificationStatus === "verified" ? "dashboard" : "verification"}`);
  const t = translator(locale);
  return (
    <AuthShell locale={locale} path="/login" title={t("login.title")}>
      {error ? <p className="error" role="alert">{t(`login.errors.${error}`)}</p> : null}
      {reset ? <p className="notice">{t("reset.done")}</p> : null}
      <form method="post" action="/api/auth/login" className="form">
        <input type="hidden" name="locale" value={locale} />
        <Field label={t("common.email")} name="email"><input id="email" name="email" type="email" required dir="ltr" autoComplete="email" defaultValue={email} /></Field>
        <Field label={t("common.password")} name="password"><input id="password" name="password" type="password" required autoComplete="current-password" /></Field>
        <div className="actions">
          <Link href={`/${locale}/forgot-password`} className="muted">{t("login.forgot")}</Link>
          <button type="submit" className="button">{t("nav.login")}</button>
        </div>
      </form>
      {error === "unverifiedEmail" && email ? (
        <form method="post" action="/api/auth/resend" className="inline-form">
          <input type="hidden" name="locale" value={locale} />
          <input type="hidden" name="email" value={email} />
          <button type="submit" className="button-secondary">{t("checkEmail.resend")}</button>
        </form>
      ) : null}
      <p className="muted">{t("login.noAccount")} <Link href={`/${locale}/create-account`}>{t("nav.createAccount")}</Link></p>
    </AuthShell>
  );
}
