import Link from "next/link";
import { notFound } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { PageHead } from "@/components/ms";
import { getSession } from "@/lib/session";
import { findWaitingMark, getVerifyMark, listWaitingMarks, requestMarkPages, requestTranslation } from "@/lib/ops";
import { AuxProvider, PageFrame, TrNote, TrUnder } from "./aux";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f-]{36}$/;

/**
 * Operations Console → Verify marks → one issue (plan item A2): one mark at a time, what the AI reader read on one
 * side and the gazette page on the other. The reviewer corrects what is wrong and confirms, or removes something
 * that is not a mark. The mark's own wording is kept exactly as printed and is never translated.
 *
 * A translation of the other fields into the page's language is asked for as soon as a mark is opened (and for the
 * two marks after it), and shown in its own box under each field (Founder, 22 Nov 2026). It is an aid: what is
 * saved is always the registry's own text. The gazette page(s) of a mark of a large bulletin are cut out of the
 * issue when the mark is opened; both arrive on the page by themselves.
 */
export default async function OpsVerifyIssue({ params, searchParams }: { params: Promise<{ locale: string; issue: string }>; searchParams: Promise<{ m?: string; no?: string; saved?: string; error?: string }> }) {
  const { locale, issue } = await params;
  const { m, no, saved, error } = await searchParams;
  if (!isLocale(locale) || !UUID.test(issue)) notFound();
  const t = translator(locale);
  const waiting = await listWaitingMarks(issue);
  // a mark asked for by its number as printed
  const asked = no && no.trim() ? await findWaitingMark(issue, no.trim().slice(0, 60)) : null;
  const want = asked ?? (m && UUID.test(m) ? m : null);
  const at = want ? waiting.findIndex((w) => w.id === want) : -1;
  const index = at >= 0 ? at : 0;
  const current = waiting[index]?.id;
  const mark = current ? await getVerifyMark(issue, current, locale) : null;
  const notes = (
    <>
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`ops.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`ops.errors.${error}`)}</div></div> : null}
      {no && no.trim() && !asked ? <div className="ms-note" role="status"><div className="ms-note__t">{t("ops.verify.find.none", { no: no.trim().slice(0, 60) })}</div></div> : null}
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
  // the translation and the page are asked for now; the page puts them in place when they arrive
  const session = await getSession();
  let pagePending = false;
  if (session) {
    try {
      if (!mark.t && !mark.t_pending) { await requestTranslation(session, issue, mark.id, locale); mark.t_pending = true; }
      for (const w of [waiting[index + 1], waiting[index + 2]]) if (w) await requestTranslation(session, issue, w.id, locale);
      if (!mark.has_page && mark.page) { await requestMarkPages(session, issue, mark.id); pagePending = true; }
    } catch (e) { console.error(JSON.stringify({ level: "error", at: "ops.verify.ask", message: (e as Error).message })); }
  }
  const lang = t(`lang.names.${locale}`);
  const trLabel = t("ops.verify.tr.title", { lang });
  const byCodes = mark.read_by === "codes" || mark.read_by === "labels";
  // a very long list is shown as read; it is not sent back with the form (the form keeps 20,000 characters at most)
  const longGoods = (mark.goods ?? "").length > 19000;
  const field = (name: string, label: string, value: string | null, extra: Record<string, unknown> = {}) => (
    <label className="ms-field"><span className="ms-field__l">{label}</span><input className="ms-input" name={name} defaultValue={value ?? ""} {...extra} /></label>
  );
  return (
    <AuxProvider url={`/api/ops/aux?issue=${issue}&mark=${mark.id}&lang=${locale}`} initial={{ t: mark.t, t_pending: mark.t_pending, has_page: mark.has_page, page_pending: pagePending }}>
      <PageHead title={t("ops.verify.oneTitle", { code: mark.code, issue: mark.issue_no })} sub={t("ops.verify.oneSub")} />
      <div className="vq__top">
        <Link href={`/${locale}/ops/verify`}>{t("ops.verify.back")}</Link>
        <form method="get" action={`/${locale}/ops/verify/${issue}`} className="vq__find">
          <label className="ms-cap" htmlFor="vq-no">{t("ops.verify.find.label")}</label>
          <input id="vq-no" className="ms-input" name="no" dir="ltr" placeholder={mark.application_no ?? ""} maxLength={60} />
          <button type="submit" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.verify.find.go")}</button>
        </form>
      </div>
      {notes}
      <div className="vq">
        <section className="vq__form ops-src">
          <div className="ops-src__head">
            <div><b>{t("ops.verify.position", { n: mark.total - mark.waiting + 1, total: mark.total })}</b><div className="ms-cap">{t("ops.verify.waitingN", { n: mark.waiting })}{mark.page ? ` · ${t("ops.verify.pdfPage", { n: mark.page })}` : ""}{mark.printed_page ? ` · ${t("ops.reading.printed", { n: mark.printed_page })}` : ""}</div></div>
            <div className="ops-src__state">{byCodes ? <span className={low ? "flag flag-amber" : "flag flag-green"}>{t(low ? "ops.verify.byCodesPart" : "ops.verify.byCodes")}</span>
              : typeof mark.confidence === "number" ? <span className={low ? "flag flag-amber" : "flag flag-green"}>{t("ops.verify.sure", { n: Math.round(mark.confidence * 100) })}</span> : null}</div>
          </div>
          <form method="post" action="/api/ops/verify" className="vq__fields">
            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="issue" value={issue} /><input type="hidden" name="mark" value={mark.id} /><input type="hidden" name="next" value={next} />
            <div className="vq__c2">{field("application_no", t("ops.verify.f.number"), mark.application_no, { dir: "ltr", inputMode: "numeric" })}</div>
            <div className="vq__c2">{field("filing_date", t("ops.verify.f.filed"), mark.filing_date && /^\d{4}-\d{2}-\d{2}$/.test(mark.filing_date) ? mark.filing_date : "", { type: "date" })}</div>
            <div className="vq__c1">{field("classes", t("ops.verify.f.classes"), mark.classes.join(", "), { dir: "ltr", inputMode: "numeric" })}</div>
            <div className="vq__c1">{field("applicant_country", t("ops.verify.f.country"), mark.applicant_country, { dir: "ltr", maxLength: 2, style: { textTransform: "uppercase" } })}</div>
            <div className="vq__c3">{field("mark_text_ar", t("ops.verify.f.markAr"), mark.mark_text_ar, { dir: "rtl", lang: "ar" })}</div>
            <div className="vq__c3">{field("mark_text_en", t("ops.verify.f.markEn"), mark.mark_text_en, { dir: "ltr" })}</div>
            <div className="vq__wide">{field("applicant_name", t("ops.verify.f.applicant"), mark.applicant_name, { dir: "auto" })}<TrUnder field="applicant_name" label={trLabel} /></div>
            <div className="vq__c4">{field("agent_name", t("ops.verify.f.agent"), mark.agent_name, { dir: "auto" })}</div>
            <div className="vq__c2">{field("agent_city", t("ops.verify.f.agentCity"), mark.agent_city, { dir: "auto" })}</div>
            <div className="vq__wide vq__under"><TrUnder field="agent_name" also="agent_city" label={trLabel} /></div>
            <div className="vq__wide"><label className="ms-field"><span className="ms-field__l">{t("ops.verify.f.address")}</span>
              <textarea className="ms-input vq__text" name="applicant_address" rows={2} dir="auto" maxLength={1000} defaultValue={mark.applicant_address ?? ""} /></label><TrUnder field="applicant_address" label={trLabel} /></div>
            <div className="vq__wide"><label className="ms-field"><span className="ms-field__l">{t("ops.verify.f.goods")}</span>
              {longGoods
                ? <textarea className="ms-input vq__text vq__goods" rows={10} dir="auto" readOnly defaultValue={mark.goods ?? ""} />
                : <textarea className="ms-input vq__text vq__goods" name="goods" rows={10} dir="auto" maxLength={20000} defaultValue={mark.goods ?? ""} />}</label>
              {longGoods ? <p className="ms-cap">{t("ops.verify.goodsLong", { n: (mark.goods ?? "").length.toLocaleString(locale) })}</p> : null}
              <TrUnder field="goods" label={trLabel} pendingText={t("ops.verify.tr.pending")} /></div>
            {mark.goods && /…\s*$/.test(mark.goods) ? <p className="ms-cap vq__wide"><span className="flag flag-amber">{t("ops.verify.goodsShort")}</span></p> : null}
            {mark.mark_type || mark.has_image || mark.international_no || mark.figure_codes ? <p className="ms-cap vq__wide">{[
              mark.mark_type || mark.has_image ? `${t("ops.verify.f.kind")}: ${[mark.mark_type ? t(`ops.verify.kinds.${mark.mark_type}`) : null, mark.has_image && mark.image_description ? `${t("ops.reading.image")}: ${mark.image_description}` : null].filter(Boolean).join(" · ")}` : null,
              mark.international_no ? t("ops.verify.intl", { no: mark.international_no }) : null,
              mark.figure_codes ? t("ops.verify.figureCodes", { codes: mark.figure_codes }) : null].filter(Boolean).join(" · ")}</p> : null}
            {byCodes && mark.read_notes ? <p className="ms-cap vq__wide"><span className="flag flag-amber">{mark.read_notes}</span></p> : null}
            <TrNote>{t("ops.reading.translationNote")}</TrNote>
            <p className="ms-cap vq__wide">{t("ops.verify.hint")}</p>
            <div className="vq__wide vq__acts">
              <button type="submit" name="action" value="confirm" className="ms-btn">{t("ops.verify.confirm")}</button>
              {next ? <Link className="ms-btn ms-btn--quiet" href={`/${locale}/ops/verify/${issue}?m=${next}`}>{t("ops.verify.skip")}</Link> : null}
            </div>
          </form>
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
          <PageFrame title={t("ops.verify.pageTitle")} src={`/api/ops/page?issue=${issue}&mark=${mark.id}#view=FitH`} waiting={t("ops.verify.pageComing")} none={t("ops.verify.noPage")}>
            {mark.page_from ? <p className="ms-cap">{mark.page_to && mark.page_to - mark.page_from + 1 > 4 ? t("ops.verify.pagesTrimmed", { from: mark.page_from, to: mark.page_to }) : t("ops.verify.pagesShown", { from: mark.page_from, to: mark.page_to ?? mark.page_from })}</p> : null}
            {mark.file ? <p className="ms-cap" dir="auto">{t("ops.verify.file", { name: mark.file })}</p> : null}
          </PageFrame>
        </section>
      </div>
    </AuxProvider>
  );
}
