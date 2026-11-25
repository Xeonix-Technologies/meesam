import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { getPictureMark, getPictureSpread, listLookalikes, listPictureIssues, type OpsLookalike } from "@/lib/ops";

export const dynamic = "force-dynamic";

const N = 10;

/**
 * Operations Console → Pictures → one issue: a mark's picture and the pictures of the same issue that each model
 * finds nearest to it, with both models' closeness. For judging the fingerprints on real marks before the Founder
 * rules how a picture score becomes a band (25 Nov 2026). Nothing here raises or changes an alert.
 */
export default async function OpsPictureIssue({ params, searchParams }: { params: Promise<{ locale: string; issue: string }>; searchParams: Promise<{ m?: string; no?: string; r?: string; spread?: string }> }) {
  const { locale, issue } = await params;
  const { m, no, r, spread } = await searchParams;
  if (!isLocale(locale) || !/^[0-9a-f-]{36}$/.test(issue)) notFound();
  const t = translator(locale);
  const head = (await listPictureIssues()).find((i) => i.issue_id === issue);
  if (!head) notFound();
  const asked = no && no.trim() ? no.trim().slice(0, 60) : null;
  const mark = (m && /^[0-9a-f-]{36}$/.test(m) ? await getPictureMark(issue, { id: m }) : null)
    ?? (asked ? await getPictureMark(issue, { no: asked }) : null)
    ?? (r ? await getPictureMark(issue, { random: true }) : null)
    ?? (asked ? null : await getPictureMark(issue, {}));
  const near = mark ? await listLookalikes(issue, mark.id, N) : [];
  const spreadRows = spread ? await getPictureSpread(issue) : [];
  const steps = [90, 80, 70, 60, 50, 40, 30, 20, 10, 0, -10];
  const count = (model: string, step: number) => spreadRows.find((x) => x.model === model && x.step === step)?.marks ?? 0;
  const total = (model: string) => spreadRows.filter((x) => x.model === model).reduce((n, x) => n + x.marks, 0);
  const atLeast = (model: string, step: number) => spreadRows.filter((x) => x.model === model && x.step >= step).reduce((n, x) => n + x.marks, 0);
  const share = (n: number, of: number) => (of > 0 ? `${Math.round((n / of) * 100)}%` : "—");
  const src = (id: string) => `/api/ops/picture?issue=${issue}&mark=${id}`;
  const here = `/${locale}/ops/pictures/${issue}`;
  const shared = (c: number[]) => (mark ? c.filter((x) => mark.classes.includes(x)) : []);
  const pct = (v: number | null) => (v === null ? "—" : `${v.toFixed(1)}`);
  const rows = (by: "siglip" | "dino") => near.filter((x) => (by === "siglip" ? x.rank_siglip : x.rank_dino) !== null && (by === "siglip" ? x.rank_siglip! : x.rank_dino!) <= N)
    .sort((a, b) => (by === "siglip" ? a.rank_siglip! - b.rank_siglip! : a.rank_dino! - b.rank_dino!));
  const table = (list: OpsLookalike[], by: "siglip" | "dino") => (
    <div className="ops-table"><Table head={["#", t("ops.pictures.cols.picture"), t("ops.pictures.cols.mark"), t("ops.pictures.cols.classes"), "SigLIP 2", "DINOv3"]}>
      {list.map((x, i) => (
        <tr key={x.id}>
          <td className="num">{i + 1}</td>
          <td><Link href={`${here}?m=${x.id}`} title={t("ops.pictures.choose")}><img className="la__thumb" src={src(x.id)} alt="" loading="lazy" /></Link></td>
          <td className="ops-wraps"><b className="num">{x.application_no ?? "—"}</b>
            <div dir="auto">{[x.mark_ar, x.mark_en].filter(Boolean).join(" · ") || <span className="ms-cap">{t("ops.pictures.noWording")}</span>}</div>
            <div className="ms-cap" dir="auto">{x.applicant_name ?? ""}</div></td>
          <td className="num ops-wraps">{x.classes.join(", ") || "—"}{shared(x.classes).length ? <div><span className="flag flag-amber">{t("ops.pictures.sameClass")}</span></div> : null}</td>
          <td className="num">{by === "siglip" ? <b>{pct(x.siglip)}</b> : pct(x.siglip)}{x.rank_siglip && by !== "siglip" ? <div className="ms-cap">#{x.rank_siglip}</div> : null}</td>
          <td className="num">{by === "dino" ? <b>{pct(x.dino)}</b> : pct(x.dino)}{x.rank_dino && by !== "dino" ? <div className="ms-cap">#{x.rank_dino}</div> : null}</td>
        </tr>
      ))}
    </Table></div>
  );
  return (
    <>
      <PageHead title={`${t("ops.pictures.title")} · ${head.code} ${head.issue_no}`} sub={t("ops.pictures.issueSub", { pictures: head.pictures, siglip: head.siglip, dino: head.dino })} />
      <p><Link href={`/${locale}/ops/pictures`}>← {t("ops.pictures.back")}</Link></p>
      <Panel title={t("ops.pictures.chosen")}>
        <form method="get" action={here} className="la__find">
          <label className="ms-field"><span className="ms-field__l">{t("ops.verify.find.label")}</span><input className="ms-input" name="no" defaultValue={asked ?? ""} inputMode="text" /></label>
          <button type="submit" className="ms-btn ms-btn--sm">{t("ops.verify.find.go")}</button>
          <Link className="ms-btn ms-btn--sm ms-btn--quiet" href={`${here}?r=${Date.now() % 100000}`}>{t("ops.pictures.random")}</Link>
        </form>
        {asked && !mark ? <div className="ms-note"><div className="ms-note__t">{t("ops.pictures.absent", { no: asked })}</div></div> : null}
        {mark ? (
          <div className="la__chosen">
            <img className="la__big" src={src(mark.id)} alt="" />
            <div>
              <div><b className="num">{mark.application_no ?? "—"}</b></div>
              <div dir="auto">{[mark.mark_ar, mark.mark_en].filter(Boolean).join(" · ") || <span className="ms-cap">{t("ops.pictures.noWording")}</span>}</div>
              <div className="ms-cap" dir="auto">{mark.applicant_name ?? ""}</div>
              <div className="ms-cap">{t("ops.pictures.cols.classes")}: <span className="num">{mark.classes.join(", ") || "—"}</span></div>
              {mark.same_picture > 0 ? <div className="ms-cap">{t("ops.pictures.samePicture", { n: mark.same_picture })}</div> : null}
              {!mark.has_siglip && !mark.has_dino ? <div className="ms-note"><div className="ms-note__t">{t("ops.pictures.noPrint")}</div></div> : null}
            </div>
          </div>
        ) : null}
      </Panel>
      {mark && (mark.has_siglip || mark.has_dino) ? (
        <div className="la__cols">
          <Panel title={t("ops.pictures.nearBy", { model: "SigLIP 2", n: N })}>{mark.has_siglip ? table(rows("siglip"), "siglip") : <p className="ms-sub">{t("ops.pictures.noPrint")}</p>}</Panel>
          <Panel title={t("ops.pictures.nearBy", { model: "DINOv3", n: N })}>{mark.has_dino ? table(rows("dino"), "dino") : <p className="ms-sub">{t("ops.pictures.noPrint")}</p>}</Panel>
        </div>
      ) : null}
      <p className="ms-cap">{t("ops.pictures.howToRead")}</p>
      <div id="spread" />
      <Panel title={t("ops.pictures.spread.title")}>
        <p className="ms-sub">{t("ops.pictures.spread.sub")}</p>
        {spread ? (
          <div className="ops-table"><Table head={[t("ops.pictures.spread.step"), "SigLIP 2", t("ops.pictures.spread.orMore"), "DINOv3", t("ops.pictures.spread.orMore")]}>
            {steps.map((st) => (
              <tr key={st}>
                <td className="num">{st === 90 ? "90 – 100" : st === -10 ? t("ops.pictures.spread.below") : `${st} – ${st + 9}`}</td>
                <td className="num">{count("siglip2", st)}</td>
                <td className="num">{atLeast("siglip2", st)} <span className="ms-cap">({share(atLeast("siglip2", st), total("siglip2"))})</span></td>
                <td className="num">{count("dinov3", st)}</td>
                <td className="num">{atLeast("dinov3", st)} <span className="ms-cap">({share(atLeast("dinov3", st), total("dinov3"))})</span></td>
              </tr>
            ))}
          </Table></div>
        ) : <p><Link className="ms-btn ms-btn--sm" href={`${here}?${mark ? `m=${mark.id}&` : ""}spread=1#spread`}>{t("ops.pictures.spread.show")}</Link></p>}
        <p className="ms-cap">{t("ops.pictures.spread.note")}</p>
      </Panel>
    </>
  );
}
