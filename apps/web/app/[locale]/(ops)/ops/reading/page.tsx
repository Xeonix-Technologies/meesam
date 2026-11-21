import { notFound } from "next/navigation";
import { formatDate, formatDateTime, isLocale, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { listIssues, listReadTests, READ_MODELS } from "@/lib/ops";

export const dynamic = "force-dynamic";

const TONE: Record<string, string> = { queued: "flag flag-amber", running: "flag flag-amber", done: "flag flag-green", failed: "flag flag-red" };

/**
 * Operations Console → Reading tests (plan item A1, first step; Founder ruling R2, 21 Nov 2026): a few pages of a
 * stored issue are sent to the AI reader and what it read is shown here. Nothing is loaded among the published
 * marks and nothing reaches an account; the page exists to judge the reader before the reading stage is built.
 */
export default async function OpsReading({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  const [issues, tests] = await Promise.all([listIssues(), listReadTests()]);
  const stored = issues.filter((i) => i.stored);
  return (
    <>
      <PageHead title={t("ops.reading.title")} sub={t("ops.reading.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      {lead ? (
        <Panel title={t("ops.reading.ask")}>
          {stored.length === 0 ? <p className="ms-sub">{t("ops.reading.noIssues")}</p> : (
            <form method="post" action="/api/ops" className="ops-form" style={{ borderBlockStart: 0, paddingBlockStart: 0, marginBlockStart: 0 }}>
              <input type="hidden" name="locale" value={locale} />
              <label className="ms-field ops-form__wide"><span className="ms-field__l">{t("ops.reading.issue")}</span>
                <select className="ms-input" name="id" required>
                  {stored.map((i) => <option key={i.id} value={i.id}>{`${i.code} · ${t(`ops.streams.${i.stream}`)} · ${i.issue_no}${i.published_on ? ` · ${formatDate(i.published_on, locale)}` : ""}${i.container ? ` · ${i.container.toUpperCase()}` : ""}`}</option>)}
                </select>
              </label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.firstPage")}</span><input className="ms-input" name="first_page" type="number" min={1} placeholder={t("ops.reading.auto")} /></label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.pages")}</span><input className="ms-input" name="pages" type="number" min={1} max={5} defaultValue={5} required /></label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.model")}</span>
                <select className="ms-input" name="model">{READ_MODELS.map((m) => <option key={m} value={m}>{t(`ops.reading.models.${m}`)}</option>)}</select>
              </label>
              <div><button type="submit" name="action" value="read_test" className="ms-btn ms-btn--sm">{t("ops.reading.run")}</button></div>
              <p className="ms-cap ops-form__wide">{t("ops.reading.hint")}</p>
            </form>
          )}
        </Panel>
      ) : null}
      <Panel title={`${t("ops.reading.tests")} · ${tests.length}`}>
        {tests.length === 0 ? <p className="ms-sub">{t("ops.reading.none")}</p> : (
          <div className="ops-list">
            {tests.map((x) => {
              const marks = x.result?.marks ?? [];
              return (
                <div key={x.id} className="ops-src">
                  <div className="ops-src__head">
                    <div><b><span className="num">{x.code}</span> · {x.issue_no}</b> <span className="ms-cap">· {x.page_count ? t("ops.reading.pagesOf", { from: x.first_page, to: x.first_page + x.pages - 1, n: x.page_count }) : x.auto_start ? t("ops.reading.pagesAuto", { n: x.pages }) : t("ops.reading.pagesAsked", { from: x.first_page, n: x.pages })}{x.auto_start && x.page_count ? ` (${t("ops.reading.auto")})` : ""} · {t(`ops.reading.models.${x.model}`)}</span>
                      <div className="ms-cap">{formatDateTime(x.created_at, locale)}{x.requested_by_name ? ` · ${x.requested_by_name}` : ""}{x.file_name ? <> · <span dir="ltr">{x.file_name}</span></> : null}</div>
                    </div>
                    <div className="ops-src__state"><span className={TONE[x.status] ?? "flag"}>{t(`ops.reading.status.${x.status}`)}</span>{x.status === "done" ? <span className="ms-cap">{t("ops.reading.marksN", { n: marks.length })}</span> : null}</div>
                  </div>
                  {x.error ? <div className="ms-note ms-note--danger"><div>{x.error}</div></div> : null}
                  {x.status === "done" ? (
                    <>
                      <dl className="ops-facts">
                        <div><dt>{t("ops.reading.kind")}</dt><dd>{x.result?.page_kind ?? "—"}</dd></div>
                        <div><dt>{t("ops.reading.language")}</dt><dd>{x.result?.language ?? "—"}</dd></div>
                        <div><dt>{t("ops.reading.model")}</dt><dd className="ms-cap">{t("ops.reading.size", { in: x.input_tokens ?? 0, out: x.output_tokens ?? 0, s: x.seconds ?? 0 })}</dd></div>
                        {x.result?.notes || x.result?.start ? <div><dt>{t("ops.reading.notes")}</dt><dd>{[x.result?.start, x.result?.notes].filter(Boolean).join(" ")}</dd></div> : null}
                      </dl>
                      {marks.length ? (
                        <div className="ops-table"><Table head={[t("ops.reading.cols.page"), t("ops.reading.cols.number"), t("ops.reading.cols.mark"), t("ops.reading.cols.type"), t("ops.reading.cols.classes"), t("ops.reading.cols.applicant"), t("ops.reading.cols.agent"), t("ops.reading.cols.filed"), t("ops.reading.cols.sure")]}>
                          {marks.map((m, k) => (
                            <tr key={k}>
                              <td className="num">{typeof m.page === "number" ? x.first_page + m.page - 1 : "—"}{m.printed_page !== null && m.printed_page !== undefined && m.printed_page !== "" ? <div className="ms-cap">{t("ops.reading.printed", { n: String(m.printed_page) })}</div> : null}
                                {m.continues ? <div className="ms-cap">{t("ops.reading.continues")}</div> : (m.pages ?? 1) > 1 ? <div className="ms-cap">{t("ops.reading.spans", { n: m.pages ?? 1 })}</div> : null}</td>
                              <td className="num" dir="ltr">{m.application_no ?? "—"}{m.registration_no ? <div className="ms-cap">{t("ops.reading.regNo", { n: m.registration_no })}</div> : null}</td>
                              <td className="ops-wraps">{m.mark_text_ar ? <div lang="ar" dir="rtl">{m.mark_text_ar}</div> : null}{m.mark_text_en ? <div lang="en" dir="ltr">{m.mark_text_en}</div> : null}{!m.mark_text_ar && !m.mark_text_en ? "—" : null}
                                {m.has_image ? <div className="ms-cap">{t("ops.reading.image")}{m.image_description ? `: ${m.image_description}` : ""}</div> : null}</td>
                              <td>{m.mark_type ?? "—"}</td>
                              <td className="num">{(m.classes ?? []).join(", ") || "—"}</td>
                              <td className="ops-wraps">{m.applicant_name ?? "—"}{m.applicant_country ? <span className="ms-cap num"> · {m.applicant_country}</span> : null}</td>
                              <td className="ops-wraps">{m.agent_name ?? "—"}</td>
                              <td>{m.filing_date && /^\d{4}-\d{2}-\d{2}$/.test(m.filing_date) ? formatDate(m.filing_date, locale) : (m.filing_date ?? "—")}</td>
                              <td className="num">{typeof m.confidence === "number" ? `${Math.round(m.confidence * 100)}%` : "—"}</td>
                            </tr>
                          ))}
                        </Table></div>
                      ) : null}
                    </>
                  ) : null}
                </div>
              );
            })}
          </div>
        )}
      </Panel>
    </>
  );
}
