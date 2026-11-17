import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { dashboard } from "@/lib/records";
import { timerLabel } from "@/lib/timers";
import { Btn, Due, Empty, MarkName, PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

const STAGES = [
  "pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration",
  "post_registration_recordals", "renewal_grace_expiry", "challenges", "enforcement",
] as const;
const EVENT_STAGES = new Set([6, 8, 9]);

/** Owner 3.2 / Agency 3.2 dashboard (Pilot Prototype screen 2), live from the account's records. */
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
  const acc = pickText(session.accountName, locale) || session.userName;
  const actions = (
    <>
      <Btn href={`/${locale}/records/new`} quiet>{t("dashboard.actions.addExisting")}</Btn>
      <Btn href={`/${locale}/records/request`}>{t("dashboard.actions.newFiling")}</Btn>
      {isAgency ? <Btn href={`/${locale}/clients`} quiet>{t("nav.clients")}</Btn> : <Btn href={`/${locale}/agencies`} quiet>{t("dashboard.actions.findAgency")}</Btn>}
    </>
  );
  const head = <PageHead title={t("dashboard.title")} sub={`${acc} · ${t("tagline")}`} actions={actions} />;

  if (total === 0) {
    return (
      <>
        {head}
        <Empty title={t("dashboard.emptyTitle")} body={t("dashboard.empty")} actions={<Btn href={`/${locale}/records/new`}>{t("dashboard.actions.addExisting")}</Btn>} />
        <Panel title={t("dashboard.notices")}><p className="ms-sub">{t("dashboard.noticePilot")}</p></Panel>
      </>
    );
  }

  const counters: Array<{ key: string; n: number; href?: string }> = [
    { key: "quotes", n: data.pending.quotes_received },
    { key: "appointments", n: data.pending.appointments_requested },
    { key: "deadlines", n: data.pending.awaiting_deadlines, href: `/${locale}/records` },
    { key: "unpaid", n: data.pending.unpaid_records, href: `/${locale}/records` },
    { key: "suggestions", n: data.pending.suggestions, href: `/${locale}/records` },
  ];
  const needsYou = data.pending.awaiting_deadlines + data.pending.suggestions;

  return (
    <>
      {head}
      <Panel title={t("dashboard.pending")}>
        <div className="ag-pend">
          {counters.map((c) => {
            const inner = <><span className="ms-cap">{t(`dashboard.counters.${c.key}.label`)}</span><span className="ms-tile__v num">{c.n}</span><span className="ms-cap">{t(`dashboard.counters.${c.key}.sub`)}</span></>;
            return c.href && c.n > 0 ? <Link key={c.key} href={c.href} className="ms-tile ag-counter">{inner}</Link> : <div key={c.key} className="ms-tile">{inner}</div>;
          })}
        </div>
      </Panel>

      <div className="ms-grid2 dash-grid">
        <Panel title={t("dashboard.nextDates")} sub={t("dashboard.nextDatesSub")} actions={<Link href={`/${locale}/records`} className="ms-link">{t("dashboard.openPortfolio")}</Link>}>
          {data.nextDates.length === 0 ? <p className="ms-sub">{t("dashboard.none")}</p> : (
            <Table head={[t("portfolio.cols.mark"), t("dashboard.cols.registryStage"), t("dashboard.cols.due"), t("dashboard.cols.with")]}>
              {data.nextDates.map((n) => {
                const stageIx = n.stage ? STAGES.indexOf(n.stage as (typeof STAGES)[number]) : -1;
                return (
                  <tr key={n.timer_id}>
                    <td><Link href={`/${locale}/records/${n.record_id}`} className="ms-link"><MarkName size="sm" runs={[n.mark_text?.ar, n.mark_text?.en]} /></Link></td>
                    <td>{n.registry_code}{stageIx >= 0 ? <div className="ms-cap"><span className="num">{stageIx + 1}</span> · {t(`stages.${STAGES[stageIx]}`)}</div> : null}</td>
                    <td><Due t={t} what={timerLabel(t, n.timer_type)} date={n.due_date} dateLabel={n.due_date ? formatDate(n.due_date, locale) : undefined} awaiting={n.awaiting_user_entry} /></td>
                    <td className="small">{n.with_agency ? pickText(n.with_agency, locale) : t("portfolio.self")}</td>
                  </tr>
                );
              })}
            </Table>
          )}
        </Panel>
        <div className="ms-stack">
          <Panel title={t("dashboard.alerts")}>
            {data.newAlerts ? <p><span className="num">{data.newAlerts}</span> {t("dashboard.alertsNew")}</p> : <p className="ms-sub">{t("dashboard.noAlerts")}</p>}
          </Panel>
          {needsYou > 0 ? (
            <Panel title={t("dashboard.confirm")} sub={t("dashboard.confirmSub")}>
              {data.pending.awaiting_deadlines > 0 ? <div className="ag-line"><span>{t("dashboard.pendingKinds.deadlines", { n: data.pending.awaiting_deadlines })}</span><Link href={`/${locale}/records`} className="ms-link">{t("dashboard.openPortfolio")}</Link></div> : null}
              {data.pending.suggestions > 0 ? <div className="ag-line"><span>{t("dashboard.pendingKinds.suggestions", { n: data.pending.suggestions })}</span><Link href={`/${locale}/records`} className="ms-link">{t("dashboard.openPortfolio")}</Link></div> : null}
            </Panel>
          ) : null}
          <Panel title={t("dashboard.notices")}><ul className="ms-list ms-sub"><li>{t("dashboard.noticePilot")}</li></ul></Panel>
        </div>
      </div>

      <Panel title={t("dashboard.portfolio")} sub={t("dashboard.portfolioSub")}>
        <ol className="ag-stagecount">
          {STAGES.map((s, i) => {
            const n = data.stageCounts[s] ?? 0;
            const cls = `${n ? "has" : ""}${EVENT_STAGES.has(i + 1) ? " ev" : ""}`;
            return (
              <li key={s}>
                <Link href={`/${locale}/records?stage=${s}`} className={cls}>
                  <span className="ag-stagecount__bar" />
                  <span className="ms-tile__v num" style={{ fontSize: 20 }}>{n}</span>
                  <span className="ms-cap"><span className="num">{i + 1}</span> · {t(`stages.${s}`)}</span>
                </Link>
              </li>
            );
          })}
        </ol>
      </Panel>
    </>
  );
}
