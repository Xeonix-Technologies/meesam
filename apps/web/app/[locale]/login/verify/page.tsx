import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";
import { currentChallenge } from "@/lib/twofactor";

export const dynamic = "force-dynamic";

/** Sign-in, second step: the code from the authenticator app or from the e-mail just sent. */
export default async function Verify({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ method?: string; error?: string; sent?: string }> }) {
  const { locale } = await params;
  const { method: m, error, sent } = await searchParams;
  if (!isLocale(locale)) notFound();
  const ch = await currentChallenge();
  if (!ch) redirect(`/${locale}/login`);
  const t = translator(locale);
  // the authenticator app when the user has one, unless they asked for an e-mail code; otherwise e-mail
  const method = ch.totp && m !== "email" ? "totp" : "email";
  const masked = ch.email.replace(/^(.).*(@.*)$/, "$1•••$2");
  const hidden = <input type="hidden" name="locale" value={locale} />;
  return (
    <AuthShell locale={locale} path="/login/verify" title={t("twofactor.title")}>
      {error ? <p className="error" role="alert">{t(`twofactor.errors.${error}`)}</p> : null}
      {sent ? <p className="notice">{t("twofactor.sent", { email: masked })}</p> : null}
      <p className="muted">{method === "totp" ? t("twofactor.leadApp") : t("twofactor.leadEmail", { email: masked })}</p>
      <form method="post" action="/api/auth/2fa" className="form">
        {hidden}<input type="hidden" name="method" value={method} />
        <Field label={t("twofactor.code")} name="code"><input id="code" name="code" required inputMode="numeric" pattern="[0-9 ]{6,7}" maxLength={7} dir="ltr" autoComplete="one-time-code" autoFocus /></Field>
        <div className="actions"><span /><button type="submit" className="button">{t("twofactor.verify")}</button></div>
      </form>
      <form method="post" action="/api/auth/2fa" className="inline-form">
        {hidden}<input type="hidden" name="action" value="send" />
        <button type="submit" className="button-secondary">{method === "totp" ? t("twofactor.useEmail") : t("twofactor.resend")}</button>
      </form>
      {ch.totp && method === "email" ? <p className="muted"><a href={`/${locale}/login/verify`}>{t("twofactor.useApp")}</a></p> : null}
      <form method="post" action="/api/auth/2fa" className="inline-form">
        {hidden}<input type="hidden" name="action" value="cancel" />
        <button type="submit" className="link-button muted">{t("twofactor.cancel")}</button>
      </form>
    </AuthShell>
  );
}
