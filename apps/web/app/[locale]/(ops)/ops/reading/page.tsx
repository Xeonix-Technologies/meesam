import { notFound } from "next/navigation";
import { formatDate, formatDateTime, isLocale, translator, type Locale, type Translator } from "@meesam/i18n";
import Link from "next/link";
import { PageHead, Panel } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { listIssues, listReadRuns, listReadTests, READ_LANGS, READ_MODELS } from "@/lib/ops";
import { MarksTable } from "./marks";
import { RunCard } from "./run-card";

export const dynamic = "force-dynamic";

const TONE: Record<string, string> = { queued: "flag flag-amber", running: "flag flag-amber", done: "flag flag-green", failed: "flag flag-red" };
const issueLabel = (i: { code: string; stream: string; issue_no: string; published_on: string | null; container: string | null }, locale: Locale, t: Translator) =>
  `${i.code} · ${t(`ops.streams.${i.stream}`)} · ${i.issue_no}${i.published_on ? ` · ${formatDate(i.published_on, locale)}` : ""}${i.container ? ` · ${i.container.toUpperCase()}` : ""}`;

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
  const [issues, tests, runs] = await Promise.all([listIssues(), listReadTests(), listReadRuns()]);
  const readable = issues.filter((i) => i.readable);
  const stored = issues.filter((i) => i.stored);
  // language names in the reader's own language, from the platform's own list (no names kept in code)
  const names = new Intl.DisplayNames([locale], { type: "language" });
  const langName = (c: string) => { try { return names.of(c) ?? c; } catch { return c; } };
  return (
    <>
      <PageHead title={t("ops.reading.title")} sub={t("ops.reading.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      {lead ? (
        <Panel title={t("ops.reading.whole.ask")}>
          {readable.length === 0 ? <p className="ms-sub">{t("ops.reading.whole.noIssues")}</p> : (
            <form method="post" action="/api/ops" className="ops-form" style={{ borderBlockStart: 0, paddingBlockStart: 0, marginBlockStart: 0 }}>
              <input type="hidden" name="locale" value={locale} />
              <label className="ms-field ops-form__wide"><span className="ms-field__l">{t("ops.reading.issue")}</span>
                <select className="ms-input" name="id" required>{readable.map((i) => <option key={i.id} value={i.id}>{`${issueLabel(i, locale, t)}${i.has_layout ? "" : ` · ${t("ops.reading.whole.pagesOnly")}`}`}</option>)}</select>
              </label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.model")}</span>
                <select className="ms-input" name="model">{READ_MODELS.map((m) => <option key={m} value={m}>{t(`ops.reading.models.${m}`)}</option>)}</select>
              </label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.whole.fromPage")}</span><input className="ms-input" name="from_page" inputMode="numeric" pattern="[0-9]*" dir="ltr" /></label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.whole.toPage")}</span><input className="ms-input" name="to_page" inputMode="numeric" pattern="[0-9]*" dir="ltr" /></label>
              <div><button type="submit" name="action" value="read_run" className="ms-btn ms-btn--sm">{t("ops.reading.whole.run")}</button></div>
              <p className="ms-cap ops-form__wide">{t("ops.reading.whole.hint")}</p>
            </form>
          )}
        </Panel>
      ) : null}
      <Panel title={`${t("ops.reading.whole.runs")} · ${runs.length}`}>
        {runs.length === 0 ? <p className="ms-sub">{t("ops.reading.whole.none")}</p> : (
          <div className="ops-list">
            {runs.map((r) => <RunCard key={r.id} run={r} locale={locale} t={t} lead={lead} link={<Link className="ms-btn ms-btn--sm ms-btn--quiet" href={`/${locale}/ops/reading/${r.id}`}>{t("ops.reading.whole.seeMarks", { n: r.marks })}</Link>} />)}
          </div>
        )}
      </Panel>
      {lead ? (
        <Panel title={t("ops.reading.ask")}>
          {stored.length === 0 ? <p className="ms-sub">{t("ops.reading.noIssues")}</p> : (
            <form method="post" action="/api/ops" className="ops-form" style={{ borderBlockStart: 0, paddingBlockStart: 0, marginBlockStart: 0 }}>
              <input type="hidden" name="locale" value={locale} />
              <label className="ms-field ops-form__wide"><span className="ms-field__l">{t("ops.reading.issue")}</span>
                <select className="ms-input" name="id" required>
                  {stored.map((i) => <option key={i.id} value={i.id}>{issueLabel(i, locale, t)}</option>)}
                </select>
              </label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.firstPage")}</span><input className="ms-input" name="first_page" type="number" min={1} placeholder={t("ops.reading.auto")} /></label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.pages")}</span><input className="ms-input" name="pages" type="number" min={1} max={5} defaultValue={5} required /></label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.model")}</span>
                <select className="ms-input" name="model">{READ_MODELS.map((m) => <option key={m} value={m}>{t(`ops.reading.models.${m}`)}</option>)}</select>
              </label>
              <label className="ms-field"><span className="ms-field__l">{t("ops.reading.translateTo")}</span>
                <select className="ms-input" name="translate_to"><option value="">{t("ops.reading.noTranslation")}</option>{READ_LANGS.map((c) => <option key={c} value={c}>{langName(c)}</option>)}</select>
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
                    <div><b><span className="num">{x.code}</span> · {x.issue_no}</b> <span className="ms-cap">· {x.page_count ? t("ops.reading.pagesOf", { from: x.first_page, to: x.first_page + x.pages - 1, n: x.page_count }) : x.auto_start ? t("ops.reading.pagesAuto", { n: x.pages }) : t("ops.reading.pagesAsked", { from: x.first_page, n: x.pages })}{x.auto_start && x.page_count ? ` (${t("ops.reading.auto")})` : ""} · {t(`ops.reading.models.${x.model}`)}{x.translate_to ? ` · ${t("ops.reading.translatedTo", { lang: langName(x.translate_to) })}` : ""}</span>
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
                      {x.translate_to ? <p className="ms-cap">{t("ops.reading.translationNote")}</p> : null}
                      {marks.length ? (
                        <MarksTable marks={marks} firstPage={x.first_page} locale={locale} t={t} />
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
