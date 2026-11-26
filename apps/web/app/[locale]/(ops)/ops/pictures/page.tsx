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
export default async function OpsPictures({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string; cmp?: string; s?: string; d?: string; same?: string }> }) {
  const { locale } = await params;
  const { error, cmp, s, d, same } = await searchParams;
  const fig = (v?: string) => (v && /^-?\d{1,3}\.\d$/.test(v) ? v : null);
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
      <div id="compare" />
      <Panel title={t("ops.pictures.compare.title")}>
        <p className="ms-sub">{t("ops.pictures.compare.sub")}</p>
        {error && ["pictureServiceOff", "pictureMissing", "pictureTooLarge", "pictureKind"].includes(error) ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.pictures.compare.errors.${error}`)}</div></div> : null}
        {cmp ? (
          <div className="ms-note ms-note--ok" role="status">
            <div className="ms-note__t">{t("ops.pictures.compare.result")}</div>
            <div className="la__result"><span>SigLIP 2: <b className="num">{fig(s) ?? "—"}</b></span><span>DINOv3: <b className="num">{fig(d) ?? "—"}</b></span></div>
            {same ? <div>{t("ops.pictures.compare.same")}</div> : null}
          </div>
        ) : null}
        <form method="post" action="/api/ops/pictures/compare" encType="multipart/form-data" className="la__find">
          <input type="hidden" name="locale" value={locale} />
          <label className="ms-field"><span className="ms-field__l">{t("ops.pictures.compare.first")}</span><input className="ms-input" type="file" name="a" accept="image/png,image/jpeg,image/webp,image/gif,image/bmp" required /></label>
          <label className="ms-field"><span className="ms-field__l">{t("ops.pictures.compare.second")}</span><input className="ms-input" type="file" name="b" accept="image/png,image/jpeg,image/webp,image/gif,image/bmp" required /></label>
          <button type="submit" className="ms-btn ms-btn--sm">{t("ops.pictures.compare.go")}</button>
        </form>
        <p className="ms-cap">{t("ops.pictures.compare.note")}</p>
      </Panel>
    </>
  );
}
