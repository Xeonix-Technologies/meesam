import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { PageHead, Panel } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { getReadRun, listRunMarks } from "@/lib/ops";
import { MarksTable } from "../marks";
import { RunCard } from "../run-card";

export const dynamic = "force-dynamic";

/**
 * Operations Console → Reading → one whole issue read (plan item A1): the run and every mark it stored, in the
 * order of the issue's pages, as the reader gave it. All of them wait for verification; none reaches an account.
 */
export default async function OpsReadRunPage({ params }: { params: Promise<{ locale: string; run: string }> }) {
  const { locale, run } = await params;
  if (!isLocale(locale) || !/^[0-9a-f-]{36}$/.test(run)) notFound();
  const t = translator(locale);
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  const [r, marks] = await Promise.all([getReadRun(run), listRunMarks(run)]);
  if (!r) notFound();
  return (
    <>
      {r.status === "queued" || r.status === "reading" ? <meta httpEquiv="refresh" content="12" /> : null}
      <PageHead title={t("ops.reading.whole.oneTitle", { code: r.code, issue: r.issue_no })} sub={t("ops.reading.whole.oneSub")} />
      <p><Link href={`/${locale}/ops/reading`}>{t("ops.reading.whole.back")}</Link></p>
      <div className="ops-list"><RunCard run={r} locale={locale} t={t} lead={lead} /></div>
      <Panel title={`${t("ops.reading.whole.marks")} · ${marks.length}`}>
        {marks.length === 0 ? <p className="ms-sub">{t("ops.reading.whole.noMarks")}</p> : <MarksTable marks={marks} firstPage={1} locale={locale} t={t} state />}
      </Panel>
    </>
  );
}
