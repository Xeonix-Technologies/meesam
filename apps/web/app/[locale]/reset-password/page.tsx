import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";

export default async function Reset({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ token?: string; error?: string }> }) {
  const { locale } = await params;
  const { token = "", error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const message = error === "bad" ? t("reset.bad") : error ? t(`register.errors.${error}`) : null;
  return (
    <AuthShell locale={locale} path="/reset-password" title={t("reset.title")}>
      {message ? <p className="error" role="alert">{message}</p> : null}
      <form method="post" action="/api/auth/reset" className="form">
        <input type="hidden" name="locale" value={locale} />
        <input type="hidden" name="token" value={token} />
        <Field label={t("common.password")} name="password" hint={t("register.passwordRule")}><input id="password" name="password" type="password" required minLength={10} autoComplete="new-password" /></Field>
        <Field label={t("common.passwordAgain")} name="password2"><input id="password2" name="password2" type="password" required minLength={10} autoComplete="new-password" /></Field>
        <div className="actions"><button type="submit" className="button" disabled={!token}>{t("reset.submit")}</button></div>
      </form>
    </AuthShell>
  );
}
