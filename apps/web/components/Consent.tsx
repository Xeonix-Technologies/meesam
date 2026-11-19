import { translator, type Locale } from "@meesam/i18n";

/**
 * The sign-up consent (Migration and Deployment Plan, Step 6): the person accepts the Terms of Use, the
 * Acceptable Use Policy and the AI and Watch Notice and confirms having read the Privacy Policy. The box is
 * never ticked in advance, and the server refuses the form without it.
 * RULING NEEDED: when the final legal versions are published, are existing users asked to accept again at next login?
 */
export function Consent({ locale, error }: { locale: Locale; error?: string }) {
  const t = translator(locale);
  const a = (slug: string) => <a href={`/${locale}/legal/${slug}`} target="_blank" rel="noopener">{t(`legal.titles.${slug}`)}</a>;
  return (
    <div className="consent">
      <label className="consent__row">
        <input type="checkbox" name="consent" value="1" required aria-invalid={error ? true : undefined} aria-describedby="consent-note" />
        <span>{t("legal.consent.accept")} {a("terms")}{t("legal.consent.sep")} {a("acceptable-use")} {t("legal.consent.and")} {a("ai-and-watch")}{t("legal.consent.read")} {a("privacy")}{t("legal.consent.end")}</span>
      </label>
      {error ? <p className="field-error" role="alert">{error}</p> : null}
      <p id="consent-note" className="muted small">{t("legal.consent.draft")}</p>
    </div>
  );
}
