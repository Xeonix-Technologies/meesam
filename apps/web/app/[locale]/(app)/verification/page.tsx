import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";

export const dynamic = "force-dynamic";

/** Until verified the user sees only the verification status and the help panel (Ruled 7 Nov 2026). */
export default async function Verification({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus === "verified") redirect(`/${locale}/dashboard`);
  const t = translator(locale);
  const status = session.verificationStatus;
  const steps = [
    { key: "email", done: status !== "pending_email" },
    { key: "review", done: false, active: status === "pending_review" },
    { key: "active", done: false },
  ];
  return (
    <div className="two-col">
      <section className="card">
        <h1>{t("verification.title")}</h1>
        <p className={`status status-${status}`}>{t(`verification.${status}.label`)}</p>
        <p>{t(`verification.${status}.body`, { email: session.email })}</p>
        <h2 className="section-title">{t("verification.whatNext")}</h2>
        <ol className="steps">
          {steps.map((s) => (
            <li key={s.key} className={s.done ? "done" : s.active ? "active" : ""}>{t(`verification.steps.${s.key}`)}</li>
          ))}
        </ol>
      </section>
      <aside className="card help">
        <h2>{t("verification.help.title")}</h2>
        <p>{t("verification.help.body")}</p>
        <p><a href={`mailto:${t("verification.help.support")}`} dir="ltr">{t("verification.help.support")}</a></p>
      </aside>
    </div>
  );
}
