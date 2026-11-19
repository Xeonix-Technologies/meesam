import { notFound } from "next/navigation";
import { formatDateTime, isLocale, pickText, translator } from "@meesam/i18n";
import { PageHead, Panel } from "@/components/ms";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { fetcherState, listSources, type FetcherState } from "@/lib/ops";

export const dynamic = "force-dynamic";

const TONE: Record<FetcherState, string> = { running: "flag flag-green", failing: "flag flag-red", paused: "flag flag-amber", inside: "flag", noLocation: "flag", off: "flag" };

/** Operations Console → Registries: every registry and stream, its profile state, re-use, fetcher and last fetch (Section 9A). */
export default async function OpsRegistries({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const session = await getSession();
  const lead = session ? (await staffRoles(session)).includes("watch_lead") : false;
  const sources = await listSources();
  const when = (v: string | null) => (v ? formatDateTime(v, locale) : "—");
  return (
    <>
      <PageHead title={t("ops.registries.title")} sub={t("ops.registries.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      <div className="ms-note ms-note--info" role="note"><div><div className="ms-note__t">{t("ops.noUploadTitle")}</div><div>{t("ops.noUpload")}</div></div></div>
      <Panel title={`${t("ops.registries.list")} · ${sources.length}`}>
        <div className="ops-list">
          {sources.map((s) => {
            const st = fetcherState(s);
            const spec = s.fetch_spec as { where?: string; reuse?: string; url?: string };
            return (
              <div key={s.id} className="ops-src">
                <div className="ops-src__head">
                  <div><b><span className="num">{s.code}</span> · {pickText(s.registry_name, locale)}</b><div>{t(`ops.streams.${s.stream}`)} <span className="ms-cap">· {s.format.toUpperCase()} · {s.cadence}</span></div></div>
                  <div className="ops-src__state"><span className={TONE[st]}>{t(`ops.state.${st}`)}</span>
                    {lead && (st === "running" || st === "failing" || st === "paused") ? (
                      <form method="post" action="/api/ops" className="inline">
                        <input type="hidden" name="locale" value={locale} /><input type="hidden" name="id" value={s.id} />
                        {st === "paused" ? <button type="submit" name="action" value="resume" className="ms-btn ms-btn--sm">{t("ops.resume")}</button> : (
                          <>
                            <button type="submit" name="action" value="poll" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.pollNow")}</button>
                            <button type="submit" name="action" value="pause" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.pause")}</button>
                          </>
                        )}
                      </form>
                    ) : null}
                  </div>
                </div>
                <dl className="ops-facts">
                  <div><dt>{t("ops.cols.profile")}</dt><dd>{s.profile_verified ? t("ops.verified") : <span className="flag flag-amber">{t("ops.unverified")}</span>} · {s.window_days ? t("ops.windowDays", { n: s.window_days }) : t("ops.windowNone")}</dd></div>
                  <div><dt>{t("ops.cols.reuse")}</dt><dd>{spec.reuse ?? "—"}</dd></div>
                  <div><dt>{t("ops.cols.location")}</dt><dd>{spec.url ? <a href={spec.url} target="_blank" rel="noopener noreferrer" dir="ltr">{new URL(spec.url).host}</a> : spec.where ?? "—"}</dd></div>
                  {st === "running" || st === "failing" || st === "paused" ? (
                    <>
                      <div><dt>{t("ops.cols.lastSuccess")}</dt><dd>{when(s.last_success_at)}</dd></div>
                      <div><dt>{t("ops.lastPolled")}</dt><dd>{when(s.last_polled_at)}{s.failures > 0 ? <> · {t("ops.failures", { n: s.failures })}</> : null}</dd></div>
                      <div><dt>{t("ops.cols.nextPoll")}</dt><dd>{st === "paused" ? (s.pause_note ?? "—") : when(s.next_poll_at)}</dd></div>
                      <div><dt>{t("ops.cols.held")}</dt><dd className="num">{s.issues}</dd></div>
                    </>
                  ) : null}
                </dl>
                {lead && st === "off" && spec.url ? (
                  <form method="post" action="/api/ops" className="ops-reuse">
                    <input type="hidden" name="locale" value={locale} /><input type="hidden" name="id" value={s.id} />
                    <label className="ms-field"><span className="ms-field__l">{t("ops.reuse.basis")}</span><input className="ms-input" name="note" required maxLength={300} placeholder={t("ops.reuse.placeholder")} /></label>
                    <button type="submit" name="action" value="reuse" className="ms-btn ms-btn--sm">{t("ops.reuse.confirm")}</button>
                    <p className="ms-cap">{t("ops.reuse.hint")}</p>
                  </form>
                ) : null}
              </div>
            );
          })}
        </div>
      </Panel>
      <p className="ms-cap">{t("ops.registries.notYet")}</p>
    </>
  );
}
