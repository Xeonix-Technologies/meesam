import { notFound } from "next/navigation";
import { formatDate, formatDateTime, isLocale, translator } from "@meesam/i18n";
import { Empty, PageHead, Panel, Table } from "@/components/ms";
import { listIssues, listSources } from "@/lib/ops";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";

export const dynamic = "force-dynamic";

const size = (b: string | null) => { const n = Number(b ?? 0); return !n ? "—" : n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`; };

/** Operations Console → Publications inbox (Section 9A): every issue received, newest first, with its file and its stage. */
export default async function OpsInbox({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const issues = await listIssues();
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  const byHand = (await listSources()).filter((x) => x.active && x.manual_intake);
  const today = new Date().toISOString().slice(0, 10);
  return (
    <>
      <PageHead title={t("ops.inbox.title")} sub={t("ops.inbox.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.manual.errors.${error}`)}</div></div> : null}
      {byHand.length ? (
        <Panel title={t("ops.manual.title")} sub={t("ops.manual.sub")}>
          <div id="by-hand" className="ops-list">
            {byHand.map((x) => {
              const page = (x.fetch_spec.manual_page ?? x.fetch_spec.url) as string | undefined;
              return (
                <div key={x.id} className="ops-src">
                  <div className="ops-src__head">
                    <div><b><span className="num">{x.code}</span> · {t(`ops.streams.${x.stream}`)}</b> {x.manual_due ? <span className="flag flag-amber">{t("ops.manual.dueNow")}</span> : x.manual_due_on ? <span className="ms-cap">{t("ops.manual.dueOn", { date: formatDate(x.manual_due_on, locale) })}</span> : null}
                      <div className="ms-cap">{t("ops.manual.lastHeld")}: {x.last_release ? formatDate(x.last_release, locale) : "—"}{page ? <> · <a href={page} target="_blank" rel="noopener noreferrer">{t("ops.manual.open")}</a></> : null}</div></div>
                  </div>
                  {lead ? (
                    <form method="post" action="/api/ops/intake" encType="multipart/form-data" className="ops-intake">
                      <input type="hidden" name="locale" value={locale} /><input type="hidden" name="source" value={x.id} />
                      <label className="ms-field"><span className="ms-field__l">{t("ops.inbox.issue")}</span><input className="ms-input" name="issue_no" required maxLength={80} dir="ltr" placeholder={typeof x.fetch_spec.start_issue === "string" ? x.fetch_spec.start_issue : undefined} /></label>
                      <label className="ms-field"><span className="ms-field__l">{t("ops.inbox.issueDate")}</span><input className="ms-input" name="published_on" type="date" required max={today} /></label>
                      <label className="ms-field"><span className="ms-field__l">{t("ops.manual.file", { kind: String(x.fetch_spec.container ?? "pdf").toUpperCase() })}</span><input className="ms-input" name="file" type="file" required accept={`.${String(x.fetch_spec.container ?? "pdf")}`} /></label>
                      <button type="submit" className="ms-btn">{t("ops.manual.addBtn")}</button>
                    </form>
                  ) : null}
                </div>
              );
            })}
          </div>
          <p className="ms-cap">{t("ops.manual.rule")}</p>
        </Panel>
      ) : null}
      <Panel title={`${t("ops.inbox.list")} · ${issues.length}`}>
        {issues.length === 0 ? <Empty title={t("ops.inbox.none")} body={t("ops.inbox.noneBody")} /> : (
          <Table head={[t("ops.cols.registry"), t("ops.cols.stream"), t("ops.inbox.issue"), t("ops.inbox.issueDate"), t("ops.inbox.file"), t("ops.inbox.received"), t("ops.inbox.stage"), t("ops.inbox.window")]}>
            {issues.map((i) => (
              <tr key={i.id}>
                <td><b className="num">{i.code}</b></td>
                <td>{t(`ops.streams.${i.stream}`)}</td>
                <td><b className="num">{i.issue_no}</b>{i.source_url ? <div className="ms-cap"><a href={i.source_url} target="_blank" rel="noopener noreferrer">{t("ops.inbox.source")}</a></div> : null}</td>
                <td>{i.published_on ? formatDate(i.published_on, locale) : t("ops.toConfirm")}</td>
                <td>{i.stored ? <><span className="num">{(i.container ?? "").toUpperCase()} · {size(i.size_bytes)}</span><div className="ms-cap num" dir="ltr">{i.checksum}…</div></> : "—"}</td>
                <td>{i.fetched_at ? formatDateTime(i.fetched_at, locale) : "—"}{i.intake === "manual" ? <div className="ms-cap">{t("ops.manual.addedBy", { name: i.added_by_name ?? "—" })}</div> : null}{i.attempts > 1 ? <div className="ms-cap">{t("ops.inbox.attempts", { n: i.attempts })}</div> : null}</td>
                <td>{i.fetch_status === "failed" ? <span className="flag flag-red">{t("ops.stage.failed")}</span> : i.stored ? <span className="flag flag-green">{t("ops.stage.received")}</span> : <span className="flag">{t("ops.stage.duplicate")}</span>}</td>
                <td>{i.window_end ? <>{formatDate(i.window_end, locale)}<div className="ms-cap">{(i.days_left ?? 0) >= 0 ? t("ops.daysLeft", { n: i.days_left ?? 0 }) : t("ops.windowClosed")}</div></> : t("ops.windowNone")}</td>
              </tr>
            ))}
          </Table>
        )}
      </Panel>
      <p className="ms-cap">{t("ops.inbox.notYet")}</p>
    </>
  );
}
