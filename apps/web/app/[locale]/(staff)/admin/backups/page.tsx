import { notFound } from "next/navigation";
import { formatDateTime, isLocale, translator } from "@meesam/i18n";
import { listBackups } from "@/lib/staff";
import { PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/**
 * System Admin → Backups (plan item A7; Founder ruling R15, 21 Nov 2026): the second copy of the database the worker
 * makes each night in another company's storage, each run with its size and outcome, and the restore tests.
 * A system administrator can ask for a copy now. No copy can be downloaded or restored from this page.
 */
export default async function AdminBackups({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const runs = await listBackups();
  const lastGood = runs.find((r) => r.ok);
  const lastTest = runs.find((r) => r.restore_ok);
  const running = runs.some((r) => r.ok === null);
  const size = (b: string | null) => (b ? `${(Number(b) / (1024 * 1024)).toFixed(Number(b) < 10 * 1024 * 1024 ? 2 : 0)} MB` : "—");
  return (
    <>
      <PageHead title={t("admin.backups.title")} sub={t("admin.backups.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`admin.backups.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`admin.backups.errors.${error}`)}</div></div> : null}
      <Panel title={t("admin.backups.state")}>
        <dl className="ops-facts">
          <div><dt>{t("admin.backups.lastGood")}</dt><dd>{lastGood ? formatDateTime(lastGood.started_at, locale) : <span className="flag flag-amber">{t("admin.backups.never")}</span>}</dd></div>
          <div><dt>{t("admin.backups.lastTest")}</dt><dd>{lastTest ? formatDateTime(lastTest.started_at, locale) : <span className="flag flag-amber">{t("admin.backups.never")}</span>}</dd></div>
          <div><dt>{t("admin.backups.where")}</dt><dd>{t("admin.backups.whereText")}</dd></div>
          <div><dt>{t("admin.backups.keep")}</dt><dd>{t("admin.backups.keepText")}</dd></div>
        </dl>
        <form method="post" action="/api/admin/backup" className="ops-src__state" style={{ marginBlockStart: 12 }}>
          <input type="hidden" name="locale" value={locale} />
          <button type="submit" name="action" value="copy" className="ms-btn ms-btn--sm" disabled={running}>{t("admin.backups.now")}</button>
          <button type="submit" name="action" value="restore_test" className="ms-btn ms-btn--sm ms-btn--quiet" disabled={running}>{t("admin.backups.nowWithTest")}</button>
          {running ? <span className="ms-cap">{t("admin.backups.running")}</span> : null}
        </form>
        <p className="ms-cap">{t("admin.backups.hint")}</p>
      </Panel>
      <Panel title={`${t("admin.backups.runs")} · ${runs.length}`}>
        {runs.length === 0 ? <p className="ms-sub">{t("admin.backups.none")}</p> : (
          <div className="ops-table"><Table head={[t("admin.backups.cols.started"), t("admin.backups.cols.why"), t("admin.backups.cols.result"), t("admin.backups.cols.size"), t("admin.backups.cols.objects"), t("admin.backups.cols.restore"), t("admin.backups.cols.detail")]}>
            {runs.map((r) => (
              <tr key={r.id}>
                <td>{formatDateTime(r.started_at, locale)}</td>
                <td>{t(`admin.backups.trigger.${r.trigger}`)}{r.requested_by_name ? <div className="ms-cap">{r.requested_by_name}</div> : null}</td>
                <td>{r.ok === null ? <span className="flag flag-amber">{t("admin.backups.result.running")}</span> : r.ok ? <span className="flag flag-green">{t("admin.backups.result.ok")}</span> : <span className="flag flag-red">{t("admin.backups.result.failed")}</span>}</td>
                <td className="num">{size(r.bytes)}</td>
                <td className="num">{r.entries ?? "—"}</td>
                <td>{r.restore_ok === null ? "—" : r.restore_ok ? <span className="flag flag-green">{t("admin.backups.restore.ok", { n: r.restore?.counts?.restored?.tables ?? 0, s: r.restore?.seconds ?? 0 })}</span> : <span className="flag flag-red">{t("admin.backups.restore.failed")}</span>}</td>
                <td className="ops-detail">{r.error ?? r.restore?.error ?? (r.restore?.mismatch ? t("admin.backups.restore.mismatch") : r.deleted_at ? t("admin.backups.removed", { date: formatDateTime(r.deleted_at, locale) }) : "")}</td>
              </tr>
            ))}
          </Table></div>
        )}
      </Panel>
    </>
  );
}
