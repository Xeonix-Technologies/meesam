import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { consumeToken } from "@/lib/auth";

export const dynamic = "force-dynamic";

/** The link from the confirmation e-mail: single use, 24 hours. */
export default async function VerifyEmail({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ token?: string }> }) {
  const { locale } = await params;
  const { token } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const userId = token ? await consumeToken(token, "email_verify") : null;
  const key = userId ? "ok" : "bad";
  return (
    <AuthShell locale={locale} path="/verify-email" title={t(`verifyEmail.${key}.title`)}>
      <p>{t(`verifyEmail.${key}.body`)}</p>
      <p><Link href={`/${locale}/login`} className="button">{t("nav.login")}</Link></p>
    </AuthShell>
  );
}
