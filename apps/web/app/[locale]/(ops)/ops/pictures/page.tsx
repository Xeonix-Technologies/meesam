import Link from "next/link";
import { notFound } from "next/navigation";
import { formatDate, isLocale, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { listPictureIssues } from "@/lib/ops";

export const dynamic = "force-dynamic";

/**
 * Operations Console → Pictures: the issues whose marks have a picture cut out of the bulletin, with how many carry
 * each model's fingerprint. A staff view for judging the fingerprints before any rule is made; nothing here is compared for alerts.
 */
export default async function OpsPictures({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const issues = await listPictureIssues();
  return (
    <>
      <PageHead title={t("ops.pictures.title")} sub={t("ops.pictures.sub")} />
      <Panel title={`${t("ops.pictures.issues")} · ${issues.length}`}>
        {issues.length === 0 ? <p className="ms-sub">{t("ops.pictures.none")}</p> : (
          <div className="ops-table"><Table head={[t("ops.verify.cols.issue"), t("ops.verify.cols.published"), t("ops.verify.cols.marks"), t("ops.pictures.cols.pictures"), "SigLIP 2", "DINOv3", ""]}>
            {issues.map((i) => (
              <tr key={i.issue_id}>
                <td className="ops-wraps"><b><span className="num">{i.code}</span> · {i.issue_no}</b><div className="ms-cap">{t(`ops.streams.${i.stream}`)}</div></td>
                <td>{i.published_on ? formatDate(i.published_on, locale) : "—"}</td>
                <td className="num">{i.total}</td>
                <td className="num">{i.pictures}</td>
                <td className="num">{i.siglip}</td>
                <td className="num">{i.dino}</td>
                <td>{i.siglip + i.dino > 0 ? <Link className="ms-btn ms-btn--sm" href={`/${locale}/ops/pictures/${i.issue_id}`}>{t("ops.pictures.open")}</Link> : <span className="ms-cap">{t("ops.pictures.noPrints")}</span>}</td>
              </tr>
            ))}
          </Table></div>
        )}
        <p className="ms-cap">{t("ops.pictures.note")}</p>
      </Panel>
    </>
  );
}
