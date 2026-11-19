import { notFound } from "next/navigation";
import { formatDate, formatDateTime, isLocale, translator } from "@meesam/i18n";
import { Empty, PageHead, Panel, Table } from "@/components/ms";
import { listIssues } from "@/lib/ops";

export const dynamic = "force-dynamic";

const size = (b: string | null) => { const n = Number(b ?? 0); return !n ? "—" : n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`; };

/** Operations Console → Publications inbox (Section 9A): every issue received, newest first, with its file and its stage. */
export default async function OpsInbox({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const issues = await listIssues();
  return (
    <>
      <PageHead title={t("ops.inbox.title")} sub={t("ops.inbox.sub")} />
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
                <td>{i.fetched_at ? formatDateTime(i.fetched_at, locale) : "—"}{i.attempts > 1 ? <div className="ms-cap">{t("ops.inbox.attempts", { n: i.attempts })}</div> : null}</td>
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
