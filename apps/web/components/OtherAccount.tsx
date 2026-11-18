import { translator, type Locale } from "@meesam/i18n";
import { PageHead } from "./ms";

/**
 * Shown when a link from an e-mail was meant for another account than the one signed in in this browser
 * (one browser holds one login). Says who is signed in and offers to log out; nothing of either account is shown.
 */
export function OtherAccount({ locale, name, email }: { locale: Locale; name: string; email: string }) {
  const t = translator(locale);
  return (
    <>
      <PageHead title={t("otherAccount.title")} />
      <div className="ms-note ms-note--warn" role="alert"><div className="ms-note__t">{t("otherAccount.body", { name, email })}</div></div>
      <form method="post" action="/api/auth/logout" className="ms-row">
        <input type="hidden" name="locale" value={locale} />
        <input type="hidden" name="next" value="login" />
        <button type="submit" className="ms-btn">{t("otherAccount.logout")}</button>
        <a className="ms-btn ms-btn--quiet" href={`/${locale}/dashboard`}>{t("otherAccount.stay")}</a>
      </form>
    </>
  );
}
