import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { Empty, PageHead, Panel, Table } from "@/components/ms";
import { listSharedIssues } from "@/lib/publications";
import { getSession } from "@/lib/session";

export const dynamic = "force-dynamic";

const size = (b: string | null) => { const n = Number(b ?? 0); return !n ? "—" : n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`; };

/**
 * Publications (Founder, 26 Nov 2026): the bulletins Meesam holds of a registry whose publications are shown to
 * signed-in accounts, newest first, each to be downloaded as the registry published it, with its source named.
 * Not a search: the marks themselves are compared by the watch, on the account's own trademarks.
 */
export default async function Publications({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (!session.isStaff && session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const issues = await listSharedIssues();
  const registries = [...new Map(issues.map((i) => [i.registry_code, i])).values()];
  return (
    <>
      <PageHead title={t("publications.title")} sub={t("publications.sub")} />
      {issues.length === 0 ? <Empty title={t("publications.none")} body={t("publications.noneBody")} /> : registries.map((g) => {
        const list = issues.filter((i) => i.registry_code === g.registry_code);
        return (
          <Panel key={g.registry_code} title={`${pickText(g.registry_name, locale) || g.registry_code} · ${list.length}`}>
            <div className="ops-table"><Table head={[t("publications.cols.issue"), t("publications.cols.date"), t("publications.cols.read"), t("publications.cols.file"), ""]}>
              {list.map((i) => (
                <tr key={i.id}>
                  <td><b className="num">{i.issue_no}</b></td>
                  <td>{i.published_on ? formatDate(i.published_on, locale) : "—"}</td>
                  <td>{i.marks + i.notices > 0 ? t("publications.read", { marks: i.marks, notices: i.notices }) : <span className="ms-cap">{t("publications.notRead")}</span>}</td>
                  <td className="num">{i.container.toUpperCase()} · {size(i.size_bytes)}</td>
                  <td><a className="ms-btn ms-btn--sm" href={`/api/publications/${i.id}`}>{t("publications.download")}</a></td>
                </tr>
              ))}
            </Table></div>
            <p className="ms-cap">{t("publications.source", { registry: pickText(g.registry_name, locale) || g.registry_code })}{g.location ? <> · <a href={g.location} target="_blank" rel="noopener noreferrer">{t("publications.sourceLink")}</a></> : null}</p>
          </Panel>
        );
      })}
      <p className="ms-cap">{t("publications.note")}</p>
    </>
  );
}
