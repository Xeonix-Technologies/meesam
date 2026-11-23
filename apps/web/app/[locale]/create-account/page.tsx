import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { signupOpen } from "@/lib/signup";
import { SignupClosed } from "@/components/SignupClosed";

export const dynamic = "force-dynamic";

/** Create account → "Who are you?" (Owner 3.1 / Agency 3.1). */
export default async function WhoAreYou({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ email?: string }> }) {
  const { locale } = await params;
  const { email } = await searchParams;
  // an agency's invitation carries the invited address, so the owner signs up with the address the request waits for
  const q = email ? `?email=${encodeURIComponent(email)}` : "";
  if (!isLocale(locale)) notFound();
  if (!signupOpen()) return <SignupClosed locale={locale} path="/create-account" />;
  const t = translator(locale);
  const kinds = email ? (["individual", "company"] as const) : (["individual", "company", "agency"] as const);
  return (
    <AuthShell locale={locale} path="/create-account" title={t("who.title")} wide>
      <p className="lead">{t(email ? "who.leadInvited" : "who.lead")}</p>
      <div className="choices">
        {kinds.map((k) => (
          <Link key={k} href={`/${locale}/create-account/${k}${q}`} className="choice">
            <strong>{t(`who.${k}.title`)}</strong>
            <span>{t(`who.${k}.body`)}</span>
          </Link>
        ))}
      </div>
      <p className="muted">{t("who.haveAccount")} <Link href={`/${locale}/login`}>{t("nav.login")}</Link></p>
    </AuthShell>
  );
}
