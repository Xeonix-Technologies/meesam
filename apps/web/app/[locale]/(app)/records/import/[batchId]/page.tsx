import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { fieldsFor, getBatch, isLoading, isStalled, type ImportRow } from "@/lib/importer";
import { PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/** One import: map the columns, review each row, load. Advisory checks never block a row (Ruled 10 Nov 2026). */
export default async function ImportBatchPage({ params, searchParams }: { params: Promise<{ locale: string; batchId: string }>; searchParams: Promise<{ error?: string; saved?: string; remap?: string }> }) {
  const { locale, batchId } = await params;
  const { error, saved, remap } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  if (!/^[0-9a-f-]{36}$/.test(batchId)) notFound();
  const got = await getBatch(session, batchId);
  if (!got || got.batch.status === "cancelled") notFound();
  const t = translator(locale);
  const { batch, rows } = got;
  const sum = batch.summary;
  const headers = sum.headers ?? [];
  const mapping = sum.mapping ?? {};
  const loading = isLoading(batch);
  const stalled = isStalled(batch);
  const mappingStep = batch.status === "staged" || (batch.status === "validated" && remap === "1" && !loading);
  const sample = (i: number) => rows.map((r) => r.raw.cells[i]).find((v) => v) ?? "";
  const hidden = <input type="hidden" name="locale" value={locale} />;
  const fields = fieldsFor(session);
  const state = (r: ImportRow) => (r.record_id ? "loaded" : r.raw.failed ? "failed" : r.errors.length ? "unreadable" : r.raw.duplicate ? "duplicate" : r.warnings.length || r.raw.notes?.length ? "warn" : "ready");
  const tone = { loaded: "ok", ready: "ok", warn: "warn", duplicate: "info", unreadable: "danger", failed: "danger" } as const;
  const detail = (r: ImportRow) => [
    ...r.errors.map((e) => t(`import.rowErrors.${e}`)),
    ...(r.raw.failed ? [t("import.rowFailed")] : []),
    ...(r.raw.duplicate ? [t("import.rowDuplicate")] : []),
    ...(r.raw.notes ?? []).map((n) => t(`import.notes.${n.code}`, { value: n.value, field: t(`import.fields.${n.field}`) })),
    ...(r.errors.length ? [] : r.warnings.map((w) => `${t(`intake.fields.${w.field}`)}: ${t(`checks.${w.code}`, w.params ?? {})}`)),
  ];
  const loadable = rows.filter((r) => state(r) === "ready" || state(r) === "warn").length;
  const loadedSoFar = rows.filter((r) => r.record_id).length;
  // a long file: the rows that need a look come first, and the table stops at 300
  const rank = { failed: 0, unreadable: 1, duplicate: 2, warn: 3, ready: 4, loaded: 5 } as const;
  const SHOWN = 300;
  const shown = rows.length > SHOWN ? [...rows].sort((a, b) => rank[state(a)] - rank[state(b)] || a.row_no - b.row_no).slice(0, SHOWN) : rows;
  const took = sum.load_started_at && sum.load_finished_at ? Math.max(1, Math.round((new Date(sum.load_finished_at).getTime() - new Date(sum.load_started_at).getTime()) / 1000)) : null;

  return (
    <>
      {loading && !stalled ? <meta httpEquiv="refresh" content="5" /> : null}
      <PageHead title={t("import.title")} sub={sum.file_name ?? ""} actions={<Link href={`/${locale}/records/import`} className="ms-link">{t("import.back")}</Link>} />
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`import.errors.${error}`, { n: 0 })}</div></div> : null}

      {mappingStep ? (
        <Panel title={t("import.step2")} sub={t("import.step2Sub", { n: rows.length })}>
          <form method="post" action={`/api/records/import/${batchId}`} className="form">
            {hidden}
            <Table head={[t("import.yourColumn"), t("import.example"), t("import.meesamField")]}>
              {headers.map((h, i) => (
                <tr key={i}><td><b>{h || `(${i + 1})`}</b></td><td className="ms-cap">{sample(i).slice(0, 60)}</td>
                  <td><select name={`col_${i}`} className="ms-input ms-input--sm" defaultValue={mapping[String(i)] ?? ""} aria-label={h}>
                    <option value="">{t("import.ignore")}</option>
                    {fields.map((f) => <option key={f} value={f}>{t(`import.fields.${f}`)}</option>)}
                  </select></td></tr>
              ))}
            </Table>
            <p className="ms-cap">{t("import.mapNote")}</p>
            <div className="ms-row" style={{ justifyContent: "space-between" }}>
              <button type="submit" name="action" value="cancel" className="ms-btn ms-btn--quiet" formNoValidate>{t("import.cancel")}</button>
              <button type="submit" name="action" value="map" className="ms-btn">{t("import.check")}</button>
            </div>
          </form>
        </Panel>
      ) : (
        <>
          {loading ? (
            <Panel title={t("import.loading")}>
              <p className="ms-sub" role="status">{t("import.loadingN", { n: loadedSoFar, total: loadedSoFar + loadable })}</p>
              <p className="ms-cap">{t(stalled ? "import.stalled" : "import.loadingNote")}</p>
              {stalled ? (
                <form method="post" action={`/api/records/import/${batchId}`} className="form">{hidden}
                  <div className="ms-row" style={{ justifyContent: "flex-end" }}><button type="submit" name="action" value="commit" className="ms-btn">{t("import.resume")}</button></div>
                </form>
              ) : null}
            </Panel>
          ) : batch.status === "committed" ? (
            <Panel title={t("import.done")}>
              {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("import.doneNote")}</div></div> : null}
              <dl className="ms-kv">
                <dt>{t("import.sum.loaded")}</dt><dd className="num">{sum.loaded ?? 0}</dd>
                <dt>{t("import.sum.warnings")}</dt><dd className="num">{sum.warnings ?? 0}</dd>
                <dt>{t("import.sum.timers")}</dt><dd className="num">{sum.timers ?? 0}</dd>
                <dt>{t("import.sum.overdue")}</dt><dd className="num">{sum.overdue ?? 0}</dd>
                <dt>{t("import.sum.due90")}</dt><dd className="num">{sum.due_90 ?? 0}</dd>
                <dt>{t("import.sum.notLoaded")}</dt><dd className="num">{(sum.unreadable ?? 0) + (sum.duplicates ?? 0) + (sum.failed ?? 0)}</dd>
                {took ? <><dt>{t("import.sum.took")}</dt><dd className="num">{took >= 120 ? t("import.minutes", { n: Math.round(took / 60) }) : t("import.seconds", { n: took })}</dd></> : null}
              </dl>
              <p className="ms-sub">{t("import.afterNote")}</p>
              <p><Link href={`/${locale}/records`} className="ms-btn">{t("dashboard.openPortfolio")}</Link></p>
            </Panel>
          ) : (
            <Panel title={t("import.step3")} sub={t("import.step3Sub")}>
              <dl className="ms-kv">
                <dt>{t("import.sum.ready")}</dt><dd className="num">{sum.ready ?? 0}</dd>
                <dt>{t("import.sum.withWarnings")}</dt><dd className="num">{sum.with_warnings ?? 0}</dd>
                <dt>{t("import.sum.duplicates")}</dt><dd className="num">{sum.duplicates ?? 0}</dd>
                <dt>{t("import.sum.unreadable")}</dt><dd className="num">{sum.unreadable ?? 0}</dd>
                {sum.clients ? <><dt>{t("import.sum.clients")}</dt><dd className="num">{sum.clients}</dd><dt>{t("import.sum.newClients")}</dt><dd className="num">{sum.new_clients ?? 0}</dd></> : null}
              </dl>
              {sum.new_clients ? <p className="ms-cap">{t("import.newClientsNote")}</p> : null}
              <form method="post" action={`/api/records/import/${batchId}`} className="form">
                {hidden}
                <div className="ms-row" style={{ justifyContent: "space-between" }}>
                  <span className="ms-row">
                    <button type="submit" name="action" value="cancel" className="ms-btn ms-btn--quiet">{t("import.cancel")}</button>
                    <button type="submit" name="action" value="remap" className="ms-btn ms-btn--quiet">{t("import.remap")}</button>
                  </span>
                  <button type="submit" name="action" value="commit" className="ms-btn" disabled={loadable === 0}>{t("import.load", { n: loadable })}</button>
                </div>
              </form>
            </Panel>
          )}
          <Panel title={t("import.rows")} sub={rows.length > shown.length ? t("import.rowsShown", { n: shown.length, total: rows.length }) : undefined}>
            <Table head={["#", t("intake.registry"), t("import.fields.mark_text_en"), t("import.numbers"), t("intake.stageReached"), t("import.result")]}>
              {shown.map((r) => {
                const d = r.raw.data ?? {};
                const st = state(r);
                const lines = detail(r);
                const name = d.mark_text_en || d.mark_text_ar || "—";
                return (
                  <tr key={r.id}>
                    <td className="num">{r.row_no}</td><td className="num">{d.registry_code ?? "—"}</td>
                    <td>{r.record_id ? <Link href={`/${locale}/records/${r.record_id}`} className="ms-link">{name}</Link> : name}{d.client_name ? <div className="ms-cap">{d.client_name}</div> : null}</td>
                    <td className="ms-cap num">{[d.application_no, d.registration_no].filter(Boolean).join(" · ") || "—"}</td>
                    <td>{d.stage ? t(`intake.stage.${d.stage}`) : "—"}</td>
                    <td><span className={`ms-tag ms-tag--${tone[st]}`}>{t(`import.state.${st}`)}</span>{lines.length ? <ul className="ms-cap">{lines.map((x, k) => <li key={k}>{x}</li>)}</ul> : null}</td>
                  </tr>
                );
              })}
            </Table>
          </Panel>
        </>
      )}
    </>
  );
}
