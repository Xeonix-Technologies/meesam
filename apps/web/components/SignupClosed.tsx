import Link from "next/link";
import { translator, type Locale } from "@meesam/i18n";
import { AuthShell } from "./AuthShell";

/** Shown in place of the sign-up pages while new accounts are closed in this environment (SIGNUP, lib/signup.ts). */
export function SignupClosed({ locale, path }: { locale: Locale; path: string }) {
  const t = translator(locale);
  return (
    <AuthShell locale={locale} path={path} title={t("who.closed.title")}>
      <p className="lead">{t("who.closed.body")}</p>
      <p className="muted">{t("who.closed.have")} <Link href={`/${locale}/login`}>{t("nav.login")}</Link></p>
    </AuthShell>
  );
}
