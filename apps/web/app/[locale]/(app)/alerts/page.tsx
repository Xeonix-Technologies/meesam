import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { ALERT_VIEWS, DISMISS_REASONS, listAlerts, pendingIssues, type AlertRow, type AlertView } from "@/lib/alerts";
import { Empty, MarkName, PageHead } from "@/components/ms";
import { OtherAccount } from "@/components/OtherAccount";

export const dynamic = "force-dynamic";

const BAND: Record<string, string> = { very_high: "flag flag-red", high: "flag flag-orange", medium: "flag flag-amber", low: "flag" };

/**
 * Watch alerts of the account (MSM-PRD-02 Section 8): a newly published mark that resembles one of the account's
 * trademarks, shown beside it with the reasons the two were matched. The wording describes the likeness and never
 * says a mark is likely to be confused with another; the decision to act is the reader's.
 * The registry's own wording is shown as published (R5: what a registry publishes is kept apart from what an account enters).
 */
export default async function Alerts({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ view?: string; saved?: string; error?: string; for?: string; record?: string; cls?: string }> }) {
  const { locale } = await params;
  const { view: viewRaw, saved, error, for: forAccount, record, cls } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  if (forAccount && forAccount !== session.accountId) return <OtherAccount locale={locale} name={pickText(session.accountName, locale) || session.userName} email={session.email} />;
  const t = translator(locale);
  const view: AlertView = (ALERT_VIEWS as readonly string[]).includes(viewRaw ?? "") ? (viewRaw as AlertView) : "open";
  const recordId = record && /^[0-9a-f-]{36}$/.test(record) ? record : undefined;
  const [alerts, pending] = await Promise.all([listAlerts(session, view, recordId, cls === "same", locale), pendingIssues(session)]);
  const canAct = session.role !== "viewer";
  const reasonText = (a: AlertRow) => {
    return a.reasons.map((r) => t(`alerts.reasons.${r.code}`, { script: r.script ? t(`alerts.script.${r.script}`) : "", pct: typeof r.score === "number" ? Math.round(r.score * 100) : 0, word: r.word ?? "" }));
  };
  const hidden = (a: AlertRow) => <><input type="hidden" name="locale" value={locale} /><input type="hidden" name="id" value={a.id} /><input type="hidden" name="view" value={view} /></>;
  return (
    <>
      <PageHead title={t("alerts.title")} sub={t("alerts.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`alerts.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`alerts.errors.${error}`)}</div></div> : null}
      {pending.length ? (
        <div className="ms-note ms-note--info" role="status"><div>
          <div className="ms-note__t">{t("alerts.pending.title")}</div>
          <ul className="al-pending">{pending.map((p) => <li key={`${p.registry_code}-${p.issue_no}`}>{p.marks === 0
            ? t("alerts.pending.unread", { registry: p.registry_code, issue: p.issue_no, date: p.published_on ? formatDate(p.published_on, locale) : "—" })
            : t("alerts.pending.review", { registry: p.registry_code, issue: p.issue_no, date: p.published_on ? formatDate(p.published_on, locale) : "—", n: p.marks, waiting: p.waiting })}</li>)}</ul>
          <div>{t("alerts.pending.note")}</div>
        </div></div>
      ) : null}
      <nav className="ms-row al-views" aria-label={t("alerts.title")}>
        {ALERT_VIEWS.map((v) => <Link key={v} href={`/${locale}/alerts?view=${v}${cls === "same" ? "&cls=same" : ""}`} className={v === view ? "ms-btn ms-btn--sm" : "ms-btn ms-btn--sm ms-btn--quiet"} aria-current={v === view ? "page" : undefined}>{t(`alerts.views.${v}`)}</Link>)}
        <span className="al-views__sep" aria-hidden="true" />
        <Link href={`/${locale}/alerts?view=${view}${cls === "same" ? "" : "&cls=same"}`} className={cls === "same" ? "ms-btn ms-btn--sm" : "ms-btn ms-btn--sm ms-btn--quiet"} aria-pressed={cls === "same"}>{t("alerts.sameClassOnly")}</Link>
      </nav>
      {alerts.length === 0 ? <Empty title={t("alerts.none")} body={t("alerts.noneBody")} /> : (
        <div className="al-list">
          {alerts.map((a) => {
            const open = a.status === "new" || a.status === "reviewing";
            return (
              <article key={a.id} id={`a-${a.id}`} className="al-card">
                <header className="al-card__head">
                  <div className="ms-row"><span className={BAND[a.band]}>{t(`alerts.band.${a.band}`)}</span><span className={a.class_kind === "same" ? "flag flag-green" : "flag"}>{a.class_kind === "same" ? t(a.class_overlap.length === 1 ? "alerts.classSame" : "alerts.classesSame", { classes: a.class_overlap.join(", ") }) : t("alerts.classDifferent")}</span><span className="flag">{t(`alerts.status.${a.status}`)}</span>
                    {a.status === "dismissed" && a.dismiss_reason ? <span className="ms-cap">{t(`alerts.dismiss.${a.dismiss_reason}`)}</span> : null}</div>
                  <div className="al-card__when">
                    {a.deadline
                      ? <><b>{t("alerts.lastDay", { date: formatDate(a.deadline, locale) })}</b> <span className={a.days_left !== null && a.days_left <= 10 ? "flag flag-red" : "flag"}>{a.days_left !== null && a.days_left >= 0 ? t("alerts.daysLeft", { n: a.days_left }) : t("alerts.windowClosed")}</span>
                          <div className="ms-cap">{t(a.deadline_by_hand ? "alerts.deadlineByHand" : "alerts.deadlineComputed")}</div></>
                      : <span className="ms-cap">{t("alerts.noDeadline")}</span>}
                  </div>
                </header>
                <div className="al-pair">
                  <section>
                    <div className="ms-cap">{t("alerts.yours")}</div>
                    <Link href={`/${locale}/records/${a.record_id}`}><MarkName size="sm" runs={[a.mark_text?.ar, a.mark_text?.en]} /></Link>
                    <div className="ms-cap num">{a.home_code ?? a.registry_code}{a.number ? ` · ${a.number}` : ""}{a.home_code && a.home_code !== a.registry_code ? <span> · {t("alerts.watchedIn", { registry: a.registry_code })}</span> : null}</div>
                    <div className="ms-cap">{t("alerts.classes", { classes: a.record_classes.join(", ") || "—" })}</div>
                  </section>
                  <section>
                    <div className="ms-cap">{t("alerts.published", { registry: a.registry_code, issue: a.issue_no, date: formatDate(a.published_on, locale) })}</div>
                    <MarkName size="sm" runs={[a.pub_text?.ar, a.pub_text?.en]} />
                    <div className="ms-cap num" dir="ltr">{a.pub_no ?? "—"}</div>
                    <div className="ms-cap">{t("alerts.classes", { classes: a.pub_classes.join(", ") || "—" })}</div>
                    {a.applicant_name ? <div className="ms-cap">{t("alerts.applicant")}: <span dir="auto">{a.applicant_name}</span>{a.applicant_country ? <span className="num"> · {a.applicant_country}</span> : null}{a.t?.applicant_name ? <div className="tr-line" dir="auto">{a.t.applicant_name}</div> : null}</div> : null}
                    {a.agent_name ? <div className="ms-cap">{t("alerts.agent")}: <span dir="auto">{a.agent_name}</span>{a.t?.agent_name ? <div className="tr-line" dir="auto">{a.t.agent_name}</div> : null}</div> : null}
                    {a.goods ? (
                      <details className="al-goods"><summary>{t("alerts.goods")}</summary>
                        <p className="ms-cap" dir="auto">{a.goods}</p>
                        {a.t?.goods ? <p className="ms-cap tr-line" dir="auto">{a.t.goods}</p> : null}
                      </details>
                    ) : null}
                    {a.t && (a.t.applicant_name || a.t.agent_name || a.t.goods) ? <div className="ms-cap al-trnote">{t("alerts.translationNote")}</div> : null}
                  </section>
                </div>
                <div className="al-why">
                  <div className="ms-cap">{t("alerts.why")}</div>
                  <ul>{reasonText(a).map((x, k) => <li key={k}>{x}</li>)}</ul>
                  <div className="ms-cap">{t("alerts.score", { pct: Math.round(a.score * 100) })}</div>
                </div>
                {canAct ? (
                  <div className="al-acts">
                    {open ? (
                      <form method="post" action="/api/alerts" className="ms-row">
                        {hidden(a)}
                        {!a.deadline ? <label className="ms-field"><span className="ms-field__l">{t("alerts.enterDeadline")}</span><input className="ms-input" type="date" name="deadline" /></label> : null}
                        {a.status === "new" ? <button type="submit" name="action" value="reviewing" className="ms-btn ms-btn--sm">{t("alerts.act.reviewed")}</button> : null}
                        <button type="submit" name="action" value="actioned" className="ms-btn ms-btn--sm ms-btn--quiet">{t("alerts.act.opposed")}</button>
                      </form>
                    ) : (
                      <form method="post" action="/api/alerts" className="ms-row">{hidden(a)}<button type="submit" name="action" value="new" className="ms-btn ms-btn--sm ms-btn--quiet">{t("alerts.act.reopen")}</button></form>
                    )}
                    {open ? (
                      <form method="post" action="/api/alerts" className="ms-row">
                        {hidden(a)}
                        <label className="ms-field"><span className="ms-field__l">{t("alerts.dismissWhy")}</span>
                          <select className="ms-input" name="reason" defaultValue="">
                            <option value="" disabled>{t("alerts.choose")}</option>
                            {DISMISS_REASONS.map((d) => <option key={d} value={d}>{t(`alerts.dismiss.${d}`)}</option>)}
                          </select>
                        </label>
                        <button type="submit" name="action" value="dismissed" className="ms-btn ms-btn--sm ms-btn--quiet">{t("alerts.act.dismiss")}</button>
                      </form>
                    ) : null}
                  </div>
                ) : null}
              </article>
            );
          })}
        </div>
      )}
      <p className="ms-cap">{t("alerts.footnote")}</p>
    </>
  );
}
