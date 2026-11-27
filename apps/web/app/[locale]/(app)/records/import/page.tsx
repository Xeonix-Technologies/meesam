import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { MAX_IMPORT_ROWS, listBatches } from "@/lib/importer";
import { PageHead, Panel } from "@/components/ms";

export const dynamic = "force-dynamic";

/** Bulk import of existing trademarks (Owner 3.5 / Agency 3.5: spreadsheet → column mapping → per-row review). */
export default async function ImportStart({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ error?: string; saved?: string }> }) {
  const { locale } = await params;
  const { error, saved } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const batches = await listBatches(session);
  return (
    <>
      <PageHead title={t("import.title")} sub={t("import.sub")} />
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`import.errors.${error}`, { n: MAX_IMPORT_ROWS })}</div></div> : null}
      {saved === "cancelled" ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("import.cancelled")}</div></div> : null}

      <Panel title={t("import.step1")}>
        <ol className="ms-sub">
          <li>{t("import.how1")} <a href="/api/records/import/template" className="ms-link">{t("import.template")}</a></li>
          <li>{t("import.how2")}</li>
          <li>{t("import.how3")}</li>
          <li>{t("import.how4", { n: MAX_IMPORT_ROWS })}</li>
        </ol>
        <form method="post" action="/api/records/import" encType="multipart/form-data" className="form upload-form">
          <input type="hidden" name="locale" value={locale} />
          <label className="ms-field"><span className="ms-field__l">{t("import.file")}</span><input name="file" type="file" accept=".xlsx,.csv,.txt,.tsv,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" required /></label>
          <div className="ms-row" style={{ justifyContent: "space-between" }}><span className="ms-cap">{t("import.nothingYet")}</span><button type="submit" className="ms-btn">{t("import.upload")}</button></div>
        </form>
      </Panel>

      {batches.length ? (
        <Panel title={t("import.earlier")}>
          {batches.map((b) => (
            <div key={b.id} className="ag-line">
              <span><b>{b.summary.file_name ?? "—"}</b> <span className="ms-cap">{formatDate(b.created_at, locale)} · {t(`import.status.${b.status}`)}{b.status === "committed" ? ` · ${t("import.loadedN", { n: b.summary.loaded ?? 0 })}` : ` · ${t("import.rowsN", { n: b.summary.rows ?? 0 })}`}</span></span>
              <Link href={`/${locale}/records/import/${b.id}`} className="ms-link">{t(b.status === "committed" ? "import.viewResult" : "import.continue")}</Link>
            </div>
          ))}
        </Panel>
      ) : null}
    </>
  );
}
