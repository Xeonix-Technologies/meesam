import Link from "next/link";
import { notFound } from "next/navigation";
import { formatDate, isLocale, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { listVerifyIssues } from "@/lib/ops";

export const dynamic = "force-dynamic";

/**
 * Operations Console → Verify marks (plan item A2): the issues whose marks were read by the AI reader, with how many
 * still wait for a person. Only a verified mark is matched to trademarks and compared for alerts.
 */
export default async function OpsVerify({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string }> }) {
  const { locale } = await params;
  const { error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const issues = await listVerifyIssues();
  return (
    <>
      <PageHead title={t("ops.verify.title")} sub={t("ops.verify.sub")} />
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      <Panel title={`${t("ops.verify.issues")} · ${issues.length}`}>
        {issues.length === 0 ? <p className="ms-sub">{t("ops.verify.none")}</p> : (
          <div className="ops-table"><Table head={[t("ops.verify.cols.issue"), t("ops.verify.cols.published"), t("ops.verify.cols.marks"), t("ops.verify.cols.waiting"), t("ops.verify.cols.verified"), t("ops.verify.cols.corrected"), ""]}>
            {issues.map((i) => (
              <tr key={i.issue_id}>
                <td><b><span className="num">{i.code}</span> · {i.issue_no}</b><div className="ms-cap">{t(`ops.streams.${i.stream}`)}</div></td>
                <td>{i.published_on ? formatDate(i.published_on, locale) : "—"}</td>
                <td className="num">{i.total}</td>
                <td className="num">{i.waiting ? <span className="flag flag-amber">{i.waiting}</span> : 0}</td>
                <td className="num">{i.total - i.waiting}</td>
                <td className="num">{i.corrected}</td>
                <td>{i.waiting ? <Link className="ms-btn ms-btn--sm" href={`/${locale}/ops/verify/${i.issue_id}`}>{t("ops.verify.start")}</Link> : <span className="flag flag-green">{t("ops.verify.allDone")}</span>}</td>
              </tr>
            ))}
          </Table></div>
        )}
      </Panel>
    </>
  );
}
