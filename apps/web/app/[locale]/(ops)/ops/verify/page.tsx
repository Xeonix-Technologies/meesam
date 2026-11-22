import Link from "next/link";
import { AutoRefresh } from "@/components/AutoRefresh";
import { notFound } from "next/navigation";
import { formatDate, isLocale, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { listVerifyIssues } from "@/lib/ops";

export const dynamic = "force-dynamic";

/**
 * Operations Console → Verify marks (plan item A2): the issues whose marks were read by the AI reader, with how many
 * still wait for a person. Only a verified mark is matched to trademarks and compared for alerts.
 */
export default async function OpsVerify({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string; saved?: string }> }) {
  const { locale } = await params;
  const { error, saved } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const issues = await listVerifyIssues();
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  // while marks are being compared the page refreshes itself
  const busy = issues.some((i) => i.waiting_jobs > 0);
  return (
    <>
      {busy ? <AutoRefresh seconds={8} /> : null}
      <PageHead title={t("ops.verify.title")} sub={t("ops.verify.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      <Panel title={`${t("ops.verify.issues")} · ${issues.length}`}>
        {issues.length === 0 ? <p className="ms-sub">{t("ops.verify.none")}</p> : (
          <div className="ops-table"><Table head={[t("ops.verify.cols.issue"), t("ops.verify.cols.published"), t("ops.verify.cols.marks"), t("ops.verify.cols.waiting"), t("ops.verify.cols.verified"), t("ops.verify.cols.compared"), t("ops.verify.cols.watched"), t("ops.verify.cols.alerts"), ""]}>
            {issues.map((i) => (
              <tr key={i.issue_id}>
                <td className="ops-wraps vq__issue"><b><span className="num">{i.code}</span> · {i.issue_no}</b><div className="ms-cap">{t(`ops.streams.${i.stream}`)}</div></td>
                <td>{i.published_on ? formatDate(i.published_on, locale) : "—"}</td>
                <td className="num">{i.total}</td>
                <td className="num">{i.waiting ? <span className="flag flag-amber">{i.waiting}</span> : 0}</td>
                <td className="num">{i.total - i.waiting}{i.accepted ? <div className="ms-cap">{t("ops.verify.acceptedN", { n: i.accepted })}</div> : null}{i.corrected ? <div className="ms-cap">{t("ops.verify.correctedN", { n: i.corrected })}</div> : null}</td>
                <td className="num">{i.compared}{i.waiting_jobs ? <div className="ms-cap">{t("ops.verify.comparing", { n: i.waiting_jobs })}</div> : null}</td>
                <td className="num">{i.watched ? i.watched : <span className="flag flag-amber">0</span>}</td>
                <td className="num ops-wraps vq__alerts">{i.alerts}<div className="ms-cap">{t("ops.verify.matches", { n: i.matches })}{i.low ? ` · ${t("ops.verify.low", { n: i.low })}` : ""}{i.own ? ` · ${t("ops.verify.own", { n: i.own })}` : ""}</div>
                  {i.held ? <div className="ms-cap vq__held">{t("ops.verify.held", { n: i.held })}</div> : null}</td>
                <td><div className="vq__rowacts">{i.waiting ? <Link className="ms-btn ms-btn--sm" href={`/${locale}/ops/verify/${i.issue_id}`}>{t("ops.verify.start")}</Link> : <span className="flag flag-green">{t("ops.verify.allDone")}</span>}
                  {lead && i.total - i.waiting > 0 ? <form method="post" action="/api/ops/verify" className="inline"><input type="hidden" name="locale" value={locale} /><input type="hidden" name="issue" value={i.issue_id} /><button type="submit" name="action" value="compare_again" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.verify.again")}</button></form> : null}</div></td>
              </tr>
            ))}
          </Table></div>
        )}
        {issues.some((i) => i.held > 0) ? <div className="ms-note"><div className="ms-note__t">{t("ops.verify.heldNote")}</div><div><Link href={`/${locale}/ops/quality`}>{t("ops.nav.quality")}</Link></div></div> : null}
        {issues.some((i) => i.watched === 0 && i.total - i.waiting > 0) ? <div className="ms-note"><div className="ms-note__t">{t("ops.verify.noWatched")}</div></div> : null}
        <p className="ms-cap">{t("ops.verify.compareNote")}</p>
      </Panel>
    </>
  );
}
