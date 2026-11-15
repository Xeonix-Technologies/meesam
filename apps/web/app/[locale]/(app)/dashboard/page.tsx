import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";

export const dynamic = "force-dynamic";

const STAGES = [
  "pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration",
  "post_registration_recordals", "renewal_grace_expiry", "challenges", "enforcement",
] as const;

/** Owner 3.2 / Agency 3.2 dashboard. Record data arrives with Step 3.4; today every panel shows its empty state. */
export default async function Dashboard({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const isAgency = session.accountKind === "agency_office";
  return (
    <>
      <h1>{t("dashboard.welcome", { name: session.userName })}</h1>
      <div className="actions-row">
        <span className="button">{t("dashboard.actions.addExisting")}</span>
        <span className="button-secondary">{t("dashboard.actions.newFiling")}</span>
        <span className="button-secondary">{isAgency ? t("dashboard.actions.inviteOwner") : t("dashboard.actions.findAgency")}</span>
      </div>
      <section className="card">
        <h2>{t("dashboard.portfolio")}</h2>
        <ol className="stage-bar">
          {STAGES.map((s) => <li key={s}><span className="count">0</span><span>{t(`stages.${s}`)}</span></li>)}
        </ol>
      </section>
      <div className="grid-3">
        <section className="card"><h2>{t("dashboard.nextDates")}</h2><p className="muted">{t("dashboard.none")}</p></section>
        <section className="card"><h2>{t("dashboard.alerts")}</h2><p className="muted">{t("dashboard.none")}</p></section>
        <section className="card"><h2>{t("dashboard.pending")}</h2><p className="muted">{t("dashboard.none")}</p></section>
      </div>
      <p className="muted">{t("dashboard.empty")}</p>
    </>
  );
}
