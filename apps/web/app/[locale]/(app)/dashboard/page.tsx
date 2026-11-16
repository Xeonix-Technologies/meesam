import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { dashboard } from "@/lib/records";

export const dynamic = "force-dynamic";

const STAGES = [
  "pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration",
  "post_registration_recordals", "renewal_grace_expiry", "challenges", "enforcement",
] as const;

function timerLabel(t: ReturnType<typeof translator>, type: string): string {
  const m = type.match(/^(.*)_reminder_(\d+)m$/);
  return m ? t("timers.reminder", { clock: t(`timers.${m[1]}`), months: Number(m[2]) }) : t(`timers.${type}`);
}

/** Owner 3.2 / Agency 3.2 dashboard, live from the account's records. */
export default async function Dashboard({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const isAgency = session.accountKind === "agency_office";
  const data = await dashboard(session);
  const total = Object.values(data.stageCounts).reduce((a, b) => a + b, 0);
  const pendingItems: Array<[string, number]> = [
    ["quotes", data.pending.quotes_received], ["appointments", data.pending.appointments_requested], ["unpaid", data.pending.unpaid_records],
    ["deadlines", data.pending.awaiting_deadlines], ["suggestions", data.pending.suggestions],
  ];
  const pendingShown = pendingItems.filter(([, n]) => n > 0);
  return (
    <>
      <h1>{t("dashboard.welcome", { name: session.userName })}</h1>
      <div className="actions-row">
        <Link href={`/${locale}/records/new`} className="button">{t("dashboard.actions.addExisting")}</Link>
        <span className="button-secondary" aria-disabled="true" title={t("common.comingSoon")}>{t("dashboard.actions.newFiling")}</span>
        <span className="button-secondary" aria-disabled="true" title={t("common.comingSoon")}>{isAgency ? t("dashboard.actions.inviteOwner") : t("dashboard.actions.findAgency")}</span>
        <Link href={`/${locale}/records`} className="button-secondary">{t("portfolio.title")} ({total})</Link>
      </div>
      <section className="card">
        <h2>{t("dashboard.portfolio")}</h2>
        <ol className="stage-bar">
          {STAGES.map((s) => <li key={s}><span className="count">{data.stageCounts[s] ?? 0}</span><span>{t(`stages.${s}`)}</span></li>)}
        </ol>
      </section>
      <div className="grid-3">
        <section className="card">
          <h2>{t("dashboard.nextDates")}</h2>
          {data.nextDates.length === 0 ? <p className="muted">{t("dashboard.none")}</p> : (
            <ul className="plain">
              {data.nextDates.map((n) => (
                <li key={n.timer_id}>
                  <Link href={`/${locale}/records/${n.record_id}`}><strong>{pickText(n.mark_text, locale) || n.registry_code}</strong></Link>
                  {" — "}{timerLabel(t, n.timer_type)}
                  {n.awaiting_user_entry ? <span className="flag flag-amber">{t("record.flags.deadline")}</span> : <> · {n.due_date ? formatDate(n.due_date, locale) : ""} <span className="muted small">({t("record.daysRemaining", { n: n.days_remaining ?? 0 })})</span></>}
                  <div className="muted small">{n.with_agency ? t("dashboard.withAgency", { name: pickText(n.with_agency, locale) }) : t("dashboard.withYou")}</div>
                </li>
              ))}
            </ul>
          )}
        </section>
        <section className="card"><h2>{t("dashboard.alerts")}</h2><p className={data.newAlerts ? "" : "muted"}>{data.newAlerts || t("dashboard.none")}</p></section>
        <section className="card">
          <h2>{t("dashboard.pending")}</h2>
          {pendingShown.length === 0 ? <p className="muted">{t("dashboard.none")}</p> : <ul className="plain">{pendingShown.map(([k, n]) => <li key={k}>{t(`dashboard.pendingKinds.${k}`, { n })}</li>)}</ul>}
        </section>
      </div>
      {total === 0 ? <p className="muted">{t("dashboard.empty")}</p> : null}
    </>
  );
}
