import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { accountVerifiedOf, consumeToken } from "@/lib/auth";
import { flushStaffNotices } from "@/lib/staff";

export const dynamic = "force-dynamic";

/** The link from the confirmation e-mail: single use, 24 hours. */
export default async function VerifyEmail({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ token?: string }> }) {
  const { locale } = await params;
  const { token } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const userId = token ? await consumeToken(token, "email_verify") : null;
  // an owner invited by an agency is verified at this step, without staff review (0028); the staff are told by e-mail
  const verified = userId ? await accountVerifiedOf(userId).catch(() => false) : false;
  if (verified) await flushStaffNotices();
  const key = userId ? (verified ? "okVerified" : "ok") : "bad";
  return (
    <AuthShell locale={locale} path="/verify-email" title={t(`verifyEmail.${key}.title`)}>
      <p>{t(`verifyEmail.${key}.body`)}</p>
      <p><Link href={`/${locale}/login`} className="button">{t("nav.login")}</Link></p>
    </AuthShell>
  );
}
