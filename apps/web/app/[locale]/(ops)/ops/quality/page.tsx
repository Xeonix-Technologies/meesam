import { notFound } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { listQuality, listReuse, type OpsReuse } from "@/lib/ops";

export const dynamic = "force-dynamic";

const USES = ["store", "show", "derive", "train", "contact"] as const;

/**
 * Operations Console → Re-use and data quality (Founder ruling R8, 21 Nov 2026; Data Management and Use 8.1 and 5.6).
 * The re-use register says, per registry, what its terms allow; the fetcher's gate reads it (migration 0060).
 * The data-quality table shows, per source that is on, what was collected, what still waits to be read and verified.
 */
export default async function OpsQualityPage({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  const [reuse, quality] = await Promise.all([listReuse(), listQuality()]);
  const may = (v: boolean | null) => (v === true ? <span className="flag flag-green">{t("ops.quality.yes")}</span> : v === false ? <span className="flag flag-red">{t("ops.quality.no")}</span> : <span className="flag">{t("ops.quality.unknown")}</span>);
  const value = (r: OpsReuse, k: (typeof USES)[number]) => r[`may_${k}` as const];
  return (
    <>
      <PageHead title={t("ops.quality.title")} sub={t("ops.quality.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      <Panel title={`${t("ops.quality.register")} · ${reuse.length}`}>
        <p className="ms-cap">{t("ops.quality.registerHint")}</p>
        <div className="ops-list">
          {reuse.map((r) => (
            <div key={r.registry_id} className="ops-src">
              <div className="ops-src__head">
                <div><b><span className="num">{r.code}</span> · {pickText(r.registry_name, locale)}</b>
                  <div className="ms-cap">{t("ops.quality.sourcesOn", { n: r.sources_on })}{r.updated_at && r.updated_by_name ? <> · {t("ops.quality.updated", { date: formatDate(String(r.updated_at).slice(0, 10), locale), name: r.updated_by_name })}</> : null}</div>
                </div>
              </div>
              <dl className="ops-facts">
                <div><dt>{t("ops.quality.terms")}</dt><dd>{r.terms ?? t("ops.quality.noRow")}{r.terms_url ? <> · <a href={r.terms_url} target="_blank" rel="noreferrer noopener" dir="ltr">{t("ops.quality.termsUrl")}</a></> : null}</dd></div>
                <div><dt>{t("ops.quality.readOn")}</dt><dd>{r.read_on ? formatDate(r.read_on, locale) : "—"}</dd></div>
                {USES.map((k) => <div key={k}><dt>{t(`ops.quality.uses.${k}`)}</dt><dd>{may(value(r, k))}</dd></div>)}
                {r.note ? <div><dt>{t("ops.quality.note")}</dt><dd>{r.note}</dd></div> : null}
              </dl>
              {lead ? (
                <details className="ops-edit">
                  <summary className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.quality.edit")}</summary>
                  <form method="post" action="/api/ops" className="ops-form">
                    <input type="hidden" name="locale" value={locale} /><input type="hidden" name="id" value={r.registry_id} />
                    <label className="ms-field ops-form__wide"><span className="ms-field__l">{t("ops.quality.terms")}</span><input className="ms-input" name="terms" maxLength={1000} defaultValue={r.terms ?? ""} /></label>
                    <label className="ms-field ops-form__wide"><span className="ms-field__l">{t("ops.quality.termsUrl")}</span><input className="ms-input" name="terms_url" type="url" dir="ltr" maxLength={500} defaultValue={r.terms_url ?? ""} /></label>
                    <label className="ms-field"><span className="ms-field__l">{t("ops.quality.readOn")}</span><input className="ms-input" name="read_on" type="date" max="9999-12-31" defaultValue={r.read_on ?? ""} /></label>
                    {USES.map((k) => {
                      const v = value(r, k);
                      return (
                        <label key={k} className="ms-field"><span className="ms-field__l">{t(`ops.quality.uses.${k}`)}</span>
                          <select className="ms-input" name={k} defaultValue={v === true ? "yes" : v === false ? "no" : ""}>
                            <option value="">{t("ops.quality.unknown")}</option><option value="yes">{t("ops.quality.yes")}</option><option value="no">{t("ops.quality.no")}</option>
                          </select>
                        </label>
                      );
                    })}
                    <label className="ms-field ops-form__wide"><span className="ms-field__l">{t("ops.quality.note")}</span><input className="ms-input" name="note" maxLength={500} defaultValue={r.note ?? ""} /></label>
                    <div><button type="submit" name="action" value="reuse_set" className="ms-btn ms-btn--sm">{t("ops.quality.save")}</button></div>
                  </form>
                </details>
              ) : null}
            </div>
          ))}
        </div>
      </Panel>
      <Panel title={t("ops.quality.quality")}>
        <p className="ms-cap">{t("ops.quality.qualityHint")}</p>
        {quality.length === 0 ? <p className="ms-sub">{t("ops.quality.none")}</p> : (
          <div className="ops-table"><Table head={[t("ops.cols.registry"), t("ops.cols.stream"), t("ops.quality.cols.lastRelease"), t("ops.quality.cols.late"), t("ops.quality.cols.stored"), t("ops.quality.cols.toRead"), t("ops.quality.cols.failed"), t("ops.quality.cols.incident"), t("ops.quality.cols.marks"), t("ops.quality.cols.toVerify")]}>
            {quality.map((q) => (
              <tr key={q.id}>
                <td><b className="num">{q.code}</b></td>
                <td>{t(`ops.streams.${q.stream}`)}{q.manual_intake ? <span className="ms-cap"> · {t("ops.quality.byHand")}</span> : null}</td>
                <td>{q.last_release ? formatDate(q.last_release, locale) : "—"}</td>
                <td>{q.days_late ? <span className="flag flag-amber">{t("ops.calendar.late", { n: q.days_late })}</span> : "—"}</td>
                <td className="num">{q.stored}</td>
                <td className="num">{q.to_read > 0 ? <span className="flag flag-amber">{q.to_read}</span> : 0}</td>
                <td className="num">{q.failed_30d > 0 ? <span className="flag flag-red">{t("ops.quality.ofRuns", { f: q.failed_30d, n: q.runs_30d })}</span> : t("ops.quality.ofRuns", { f: 0, n: q.runs_30d })}</td>
                <td>{q.open_incident ? <span className="flag flag-red">{t("ops.quality.yes")}</span> : "—"}</td>
                <td className="num">{q.marks}</td>
                <td className="num">{q.to_verify > 0 ? <span className="flag flag-amber">{q.to_verify}</span> : 0}</td>
              </tr>
            ))}
          </Table></div>
        )}
      </Panel>
    </>
  );
}
