import { notFound } from "next/navigation";
import { formatDate, formatDateTime, isLocale, pickText, translator } from "@meesam/i18n";
import { Empty, PageHead, Panel, Table } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { listIncidents, listRuns } from "@/lib/ops";

export const dynamic = "force-dynamic";

/** Operations Console → Fetcher incidents (Section 9A): open "source broken" incidents, then every recent attempt and recovery step. */
export default async function OpsIncidents({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  const [incidents, runs] = await Promise.all([listIncidents(), listRuns()]);
  const open = incidents.filter((i) => !i.closed_at);
  const closed = incidents.filter((i) => i.closed_at);
  const step = (s?: string) => (s ? t(`ops.steps.${["discover", "download", "shape", "store", "record"].includes(s) ? s : "other"}`) : "—");
  return (
    <>
      <PageHead title={t("ops.incidents.title")} sub={t("ops.incidents.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}

      <Panel title={`${t("ops.incidents.open")} · ${open.length}`}>
        {open.length === 0 ? <Empty title={t("ops.incidents.none")} /> : open.map((i) => (
          <div key={i.id} className="review-card">
            <div className="review-card__head">
              <div><b><span className="num">{i.code}</span> · {t(`ops.streams.${i.stream}`)}</b> <span className="flag flag-red">{t("ops.incidents.broken")}</span>
                <div className="ms-cap">{t("ops.incidents.opened")}: {formatDateTime(i.opened_at, locale)} · {t("ops.incidents.failedAt")}: {step(i.detail.step)}{i.detail.issue_no ? ` · ${t("ops.inbox.issue")} ${i.detail.issue_no}` : ""}</div>
                {i.detail.error ? <div className="ms-cap" dir="ltr">{i.detail.error}</div> : null}</div>
              <div>{i.earliest_window_end ? <><b>{formatDate(i.earliest_window_end, locale)}</b><div className="ms-cap">{t("ops.incidents.windowAtRisk")} · {t("ops.daysLeft", { n: Math.max(0, i.days_left ?? 0) })}</div></> : <span className="ms-cap">{t("ops.incidents.noWindow")}</span>}</div>
            </div>
            {lead ? (
              <form method="post" action="/api/ops" className="form review-card__form">
                <input type="hidden" name="locale" value={locale} /><input type="hidden" name="id" value={i.id} />
                <label className="ms-field"><span className="ms-field__l">{t("ops.incidents.note")}</span><input className="ms-input" name="note" maxLength={500} /></label>
                <div className="actions"><button type="submit" name="action" value="close" className="ms-btn">{t("ops.incidents.close")}</button></div>
                <p className="ms-cap">{t("ops.incidents.closeHint")}</p>
              </form>
            ) : null}
          </div>
        ))}
      </Panel>

      <Panel title={t("ops.incidents.runs")} sub={t("ops.incidents.runsSub")}>
        {runs.length === 0 ? <Empty title={t("ops.incidents.noRuns")} /> : (
          <Table head={[t("ops.incidents.when"), t("ops.cols.registry"), t("ops.cols.stream"), t("ops.inbox.issue"), t("ops.incidents.outcome"), t("ops.incidents.detail")]}>
            {runs.map((r) => (
              <tr key={r.id}>
                <td>{formatDateTime(r.started_at, locale)}</td>
                <td><b className="num">{r.code}</b></td>
                <td>{t(`ops.streams.${r.stream}`)}</td>
                <td className="num">{r.detail.issue_no ?? "—"}</td>
                <td><span className={r.outcome === "failed" ? "flag flag-red" : r.outcome === "not_yet_published" ? "flag flag-amber" : "flag flag-green"}>{t(`ops.outcome.${r.detail.duplicate ? "duplicate" : r.outcome ?? "failed"}`)}</span>{r.outcome === "failed" ? <div className="ms-cap">{t("ops.incidents.attempt", { n: r.attempt })}</div> : null}</td>
                <td>{r.outcome === "failed" ? <>{step(r.detail.step)}<div className="ms-cap" dir="ltr">{r.detail.error}</div></> : r.detail.bytes ? <span className="num">{(r.detail.bytes / 1048576).toFixed(1)} MB</span> : "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </Panel>

      {closed.length ? (
        <Panel title={`${t("ops.incidents.closed")} · ${closed.length}`}>
          <Table head={[t("ops.cols.registry"), t("ops.incidents.opened"), t("ops.incidents.closedAt"), t("ops.incidents.closedBy"), t("ops.incidents.note")]}>
            {closed.map((i) => <tr key={i.id}><td><b className="num">{i.code}</b> · {t(`ops.streams.${i.stream}`)}</td><td>{formatDateTime(i.opened_at, locale)}</td><td>{i.closed_at ? formatDateTime(i.closed_at, locale) : "—"}</td><td>{i.closed_by_name ?? "—"}</td><td>{i.close_note ?? "—"}</td></tr>)}
          </Table>
        </Panel>
      ) : null}
      <p className="ms-cap">{t("ops.incidents.notYet")}</p>
    </>
  );
}
