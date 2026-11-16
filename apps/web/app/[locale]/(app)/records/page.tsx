import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { listPortfolio } from "@/lib/records";

export const dynamic = "force-dynamic";

/** Owner 3.3 / Agency 3.3 Portfolio: every record the account holds, primary sort by stage. */
export default async function Portfolio({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ stage?: string }> }) {
  const { locale } = await params;
  const { stage } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const all = await listPortfolio(session);
  const records = stage ? all.filter((r) => r.stage === stage) : all;
  return (
    <>
      <div className="page-head">
        <div><h1>{t("portfolio.title")}</h1>{stage ? <p className="ms-sub">{t("portfolio.filteredByStage", { stage: t(`stages.${stage}`), n: records.length, total: all.length })} · <Link href={`/${locale}/records`} className="ms-link">{t("portfolio.clearFilter")}</Link></p> : null}</div>
        <div className="actions-row compact">
          <Link href={`/${locale}/records/new`} className="button">{t("dashboard.actions.addExisting")}</Link>
        </div>
      </div>
      {records.length === 0 ? (
        <section className="card"><p className="muted">{t("portfolio.empty")}</p></section>
      ) : (
        <section className="card table-card">
          <table className="data">
            <thead>
              <tr>
                <th>{t("portfolio.cols.mark")}</th><th>{t("portfolio.cols.registry")}</th><th>{t("portfolio.cols.stage")}</th><th>{t("portfolio.cols.status")}</th>
                <th>{t("portfolio.cols.flags")}</th><th>{t("portfolio.cols.nextDate")}</th><th>{t("portfolio.cols.managedBy")}</th><th>{t("portfolio.cols.paid")}</th><th>{t("portfolio.cols.watch")}</th>
              </tr>
            </thead>
            <tbody>
              {records.map((r) => (
                <tr key={r.record_id}>
                  <td><Link href={`/${locale}/records/${r.record_id}`}><strong>{pickText(r.mark_text, locale) || r.application_no || "—"}</strong></Link><div className="muted small" dir="ltr">{r.registration_no ?? r.application_no ?? ""}</div></td>
                  <td>{r.registry_code}</td>
                  <td>{t(`stages.${r.stage}`)}</td>
                  <td>{r.status_label ? pickText(r.status_label, locale) : t(`stages.${r.stage}`)}{r.terminal ? ` · ${t("record.terminal")}` : ""}</td>
                  <td className="flags">
                    {r.holding_agency && r.poa_state !== "present" ? <span className="flag flag-red" title={t(`record.poa.${r.poa_state}`)}>POA</span> : null}
                    {(r.warnings ?? []).some((w) => !w.confirmed_at) ? <span className="flag flag-amber">{t("record.flags.warnings")}</span> : null}
                    {r.awaiting_deadline_entry ? <span className="flag flag-amber">{t("record.flags.deadline")}</span> : null}
                    {r.has_suggestions ? <span className="flag">{t("record.flags.suggestion")}</span> : null}
                  </td>
                  <td>{r.next_due_date ? <>{formatDate(r.next_due_date, locale)} <span className="muted small">({t("record.daysRemaining", { n: Math.round((new Date(r.next_due_date).getTime() - Date.now()) / 86400000) })})</span></> : "—"}</td>
                  <td>{r.holding_agency ? pickText(r.holding_agency, locale) : t("portfolio.self")}</td>
                  <td>{t(`record.paid.${r.paid_state}`)}</td>
                  <td>{r.watch_active ? t("common.on") : t("common.off")}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}
