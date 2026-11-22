import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { PageHead } from "@/components/ms";
import { getVerifyMark, listWaitingMarks } from "@/lib/ops";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f-]{36}$/;

/**
 * Operations Console → Verify marks → one issue (plan item A2): one mark at a time, what the AI reader read on one
 * side and the gazette page on the other. The reviewer corrects what is wrong and confirms, or removes something
 * that is not a mark. The mark's own wording is kept exactly as printed; nothing here is translated.
 */
export default async function OpsVerifyIssue({ params, searchParams }: { params: Promise<{ locale: string; issue: string }>; searchParams: Promise<{ m?: string; saved?: string; error?: string }> }) {
  const { locale, issue } = await params;
  const { m, saved, error } = await searchParams;
  if (!isLocale(locale) || !UUID.test(issue)) notFound();
  const t = translator(locale);
  const waiting = await listWaitingMarks(issue);
  const at = m && UUID.test(m) ? waiting.findIndex((w) => w.id === m) : -1;
  const index = at >= 0 ? at : 0;
  const current = waiting[index]?.id;
  const mark = current ? await getVerifyMark(issue, current, locale) : null;
  const notes = (
    <>
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
    </>
  );
  if (!mark) {
    return (
      <>
        <PageHead title={t("ops.verify.title")} sub={t("ops.verify.sub")} />
        {notes}
        <div className="ms-note ms-note--ok"><div className="ms-note__t">{t("ops.verify.issueDone")}</div></div>
        <p><Link href={`/${locale}/ops/verify`}>{t("ops.verify.back")}</Link></p>
      </>
    );
  }
  // the mark after this one in the queue (the first one again after the last)
  const next = waiting.length > 1 ? waiting[(index + 1) % waiting.length]!.id : "";
  const low = typeof mark.confidence === "number" && mark.confidence < 0.8;
  const tr = mark.t;
  const field = (name: string, label: string, value: string | null, extra: Record<string, unknown> = {}) => (
    <label className="ms-field"><span className="ms-field__l">{label}</span><input className="ms-input" name={name} defaultValue={value ?? ""} {...extra} /></label>
  );
  return (
    <>
      {mark.t_pending ? <meta httpEquiv="refresh" content="6" /> : null}
      <PageHead title={t("ops.verify.oneTitle", { code: mark.code, issue: mark.issue_no })} sub={t("ops.verify.oneSub")} />
      <p><Link href={`/${locale}/ops/verify`}>{t("ops.verify.back")}</Link></p>
      {notes}
      <div className="vq">
        <section className="vq__form ops-src">
          <div className="ops-src__head">
            <div><b>{t("ops.verify.position", { n: mark.total - mark.waiting + 1, total: mark.total })}</b><div className="ms-cap">{t("ops.verify.waitingN", { n: mark.waiting })}{mark.page ? ` · ${t("ops.verify.pdfPage", { n: mark.page })}` : ""}{mark.printed_page ? ` · ${t("ops.reading.printed", { n: mark.printed_page })}` : ""}</div></div>
            <div className="ops-src__state">{typeof mark.confidence === "number" ? <span className={low ? "flag flag-amber" : "flag flag-green"}>{t("ops.verify.sure", { n: Math.round(mark.confidence * 100) })}</span> : null}</div>
          </div>
          <form method="post" action="/api/ops/verify" className="vq__fields">
            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="issue" value={issue} /><input type="hidden" name="mark" value={mark.id} /><input type="hidden" name="next" value={next} />
            <div className="vq__c2">{field("application_no", t("ops.verify.f.number"), mark.application_no, { dir: "ltr", inputMode: "numeric" })}</div>
            <div className="vq__c2">{field("filing_date", t("ops.verify.f.filed"), mark.filing_date && /^\d{4}-\d{2}-\d{2}$/.test(mark.filing_date) ? mark.filing_date : "", { type: "date" })}</div>
            <div className="vq__c1">{field("classes", t("ops.verify.f.classes"), mark.classes.join(", "), { dir: "ltr", inputMode: "numeric" })}</div>
            <div className="vq__c1">{field("applicant_country", t("ops.verify.f.country"), mark.applicant_country, { dir: "ltr", maxLength: 2, style: { textTransform: "uppercase" } })}</div>
            <div className="vq__c3">{field("mark_text_ar", t("ops.verify.f.markAr"), mark.mark_text_ar, { dir: "rtl", lang: "ar" })}</div>
            <div className="vq__c3">{field("mark_text_en", t("ops.verify.f.markEn"), mark.mark_text_en, { dir: "ltr" })}</div>
            <div className="vq__wide">{field("applicant_name", t("ops.verify.f.applicant"), mark.applicant_name, { dir: "auto" })}</div>
            <div className="vq__c4">{field("agent_name", t("ops.verify.f.agent"), mark.agent_name, { dir: "auto" })}</div>
            <div className="vq__c2">{field("agent_city", t("ops.verify.f.agentCity"), mark.agent_city, { dir: "auto" })}</div>
            <label className="ms-field vq__wide"><span className="ms-field__l">{t("ops.verify.f.address")}</span>
              <textarea className="ms-input vq__text" name="applicant_address" rows={2} dir="auto" maxLength={1000} defaultValue={mark.applicant_address ?? ""} /></label>
            <label className="ms-field vq__wide"><span className="ms-field__l">{t("ops.verify.f.goods")}</span>
              <textarea className="ms-input vq__text vq__goods" name="goods" rows={10} dir="auto" maxLength={20000} defaultValue={mark.goods ?? ""} /></label>
            {mark.goods && /…\s*$/.test(mark.goods) ? <p className="ms-cap vq__wide"><span className="flag flag-amber">{t("ops.verify.goodsShort")}</span></p> : null}
            {mark.mark_type || mark.has_image ? <p className="ms-cap vq__wide">{t("ops.verify.f.kind")}: {[mark.mark_type, mark.has_image ? `${t("ops.reading.image")}${mark.image_description ? `: ${mark.image_description}` : ""}` : null].filter(Boolean).join(" · ")}</p> : null}
            <p className="ms-cap vq__wide">{t("ops.verify.hint")}</p>
            <div className="vq__wide vq__acts">
              <button type="submit" name="action" value="confirm" className="ms-btn">{t("ops.verify.confirm")}</button>
              {next ? <Link className="ms-btn ms-btn--quiet" href={`/${locale}/ops/verify/${issue}?m=${next}`}>{t("ops.verify.skip")}</Link> : null}
            </div>
          </form>
          {/* translation beside the registry's own text (migration 0080): an aid for the reviewer, never the stored value */}
          <div className="vq__tr">
            {tr && Object.keys(tr).some((k) => ["applicant_name", "applicant_address", "agent_name", "agent_city", "goods"].includes(k)) ? (
              <>
                <div className="ms-field__l">{t("ops.verify.tr.title", { lang: t(`lang.names.${locale}`) })}</div>
                <dl className="ops-facts">
                  {tr.applicant_name ? <div><dt>{t("ops.verify.f.applicant")}</dt><dd className="tr-line" dir="auto">{tr.applicant_name}</dd></div> : null}
                  {tr.agent_name ? <div><dt>{t("ops.verify.f.agent")}</dt><dd className="tr-line" dir="auto">{[tr.agent_name, tr.agent_city].filter(Boolean).join(" · ")}</dd></div> : null}
                  {tr.applicant_address ? <div><dt>{t("ops.verify.tr.address")}</dt><dd className="tr-line" dir="auto">{tr.applicant_address}</dd></div> : null}
                </dl>
                {tr.goods ? <><div className="ms-cap">{t("ops.verify.tr.goods")}</div><p className="tr-line vq__trgoods" dir="auto">{tr.goods}</p></> : null}
                <p className="ms-cap">{t("ops.reading.translationNote")}</p>
              </>
            ) : mark.t_pending ? <p className="ms-cap">{t("ops.verify.tr.pending")}</p>
              : tr ? <p className="ms-cap">{t("ops.verify.tr.same", { lang: t(`lang.names.${locale}`) })}</p> : (
              <form method="post" action="/api/ops/verify" className="inline">
                <input type="hidden" name="locale" value={locale} /><input type="hidden" name="issue" value={issue} /><input type="hidden" name="mark" value={mark.id} />
                <button type="submit" name="action" value="translate" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.verify.tr.ask", { lang: t(`lang.names.${locale}`) })}</button>
              </form>
            )}
          </div>
          <details className="vq__reject">
            <summary>{t("ops.verify.notAMark")}</summary>
            <form method="post" action="/api/ops/verify" className="ops-reuse">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="issue" value={issue} /><input type="hidden" name="mark" value={mark.id} /><input type="hidden" name="next" value={next} />
              <label className="ms-field"><span className="ms-field__l">{t("ops.verify.reason")}</span><input className="ms-input" name="reason" maxLength={300} required /></label>
              <button type="submit" name="action" value="reject" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.verify.remove")}</button>
              <p className="ms-cap">{t("ops.verify.removeHint")}</p>
            </form>
          </details>
        </section>
        <section className="vq__page">
          {mark.has_page
            ? <iframe className="vq__frame" title={t("ops.verify.pageTitle")} src={`/api/ops/page?issue=${issue}&mark=${mark.id}#view=FitH`} />
            : <div className="ms-note"><div className="ms-note__t">{t("ops.verify.noPage")}</div></div>}
          {mark.has_page && mark.page_from ? <p className="ms-cap">{mark.page_to && mark.page_to - mark.page_from + 1 > 4 ? t("ops.verify.pagesTrimmed", { from: mark.page_from, to: mark.page_to }) : t("ops.verify.pagesShown", { from: mark.page_from, to: mark.page_to ?? mark.page_from })}</p> : null}
        </section>
      </div>
    </>
  );
}
