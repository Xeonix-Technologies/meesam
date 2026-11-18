import { notFound } from "next/navigation";
import { isLocale, pickText, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { Field } from "@/components/Field";
import { invitePreview } from "@/lib/users";

export const dynamic = "force-dynamic";

/** An invited user of a company or agency account sets a password (System Description Section 3). */
export default async function AcceptInvite({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ token?: string; error?: string }> }) {
  const { locale } = await params;
  const { token = "", error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const inv = token ? await invitePreview(token).catch(() => null) : null;
  const message = error === "bad" || !inv ? t("invite.bad") : error ? t(`register.errors.${error}`) : null;
  return (
    <AuthShell locale={locale} path="/accept-invite" title={t("invite.title")}>
      {message ? <p className="error" role="alert">{message}</p> : null}
      {!inv ? <div className="actions"><a className="button" href={`/${locale}/login`}>{t("nav.login")}</a></div> : null}
      {inv ? (
        <>
          <p className="muted">{t("invite.intro", { name: inv.user_name, account: pickText(inv.account_name, locale), email: inv.email })}</p>
          <form method="post" action="/api/auth/accept-invite" className="form">
            <input type="hidden" name="locale" value={locale} />
            <input type="hidden" name="token" value={token} />
            <Field label={t("common.password")} name="password" hint={t("register.passwordRule")}><input id="password" name="password" type="password" required minLength={10} autoComplete="new-password" /></Field>
            <Field label={t("common.passwordAgain")} name="password2"><input id="password2" name="password2" type="password" required minLength={10} autoComplete="new-password" /></Field>
            <div className="actions"><button type="submit" className="button">{t("invite.submit")}</button></div>
          </form>
        </>
      ) : null}
    </AuthShell>
  );
}
