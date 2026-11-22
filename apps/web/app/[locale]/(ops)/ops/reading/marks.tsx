import { formatDate, type Locale, type Translator } from "@meesam/i18n";
import { Table } from "@/components/ms";
import type { ReadMark } from "@/lib/ops";

/**
 * The marks the AI reader gave, one row each, as printed (the registry's own wording first; a translation, where
 * one was asked for, on the lines marked ≈). `firstPage` is the PDF page of the first page read, so the page
 * shown is the page in the whole file; marks of a whole issue already carry that page (firstPage = 1).
 */
export function MarksTable({ marks, firstPage, locale, t, state }: { marks: Array<ReadMark & { verify_state?: string }>; firstPage: number; locale: Locale; t: Translator; state?: boolean }) {
  const x = { first_page: firstPage };
  return (
    <div className="ops-table"><Table head={[t("ops.reading.cols.page"), t("ops.reading.cols.number"), t("ops.reading.cols.mark"), t("ops.reading.cols.classes"), t("ops.reading.cols.applicant"), t("ops.reading.cols.agent"), t("ops.reading.cols.sure"), ...(state ? [t("ops.reading.cols.state")] : [])]}>
      {marks.map((m, k) => (
        <tr key={k}>
          <td className="num">{typeof m.page === "number" ? x.first_page + m.page - 1 : "—"}{m.printed_page !== null && m.printed_page !== undefined && m.printed_page !== "" ? <div className="ms-cap">{t("ops.reading.printed", { n: String(m.printed_page) })}</div> : null}
            {m.continues ? <div className="ms-cap">{t("ops.reading.continues")}</div> : (m.pages ?? 1) > 1 ? <div className="ms-cap">{t("ops.reading.spans", { n: m.pages ?? 1 })}</div> : null}</td>
          <td className="num" dir="ltr">{m.application_no ?? "—"}{m.registration_no ? <div className="ms-cap">{t("ops.reading.regNo", { n: m.registration_no })}</div> : null}
            {m.filing_date ? <div className="ms-cap" dir="auto">{t("ops.reading.filedOn", { date: /^\d{4}-\d{2}-\d{2}$/.test(m.filing_date) ? formatDate(m.filing_date, locale) : m.filing_date })}</div> : null}</td>
          <td className="ops-wraps"><div className="ops-cell ops-cell--wide">{m.mark_text_ar ? <div lang="ar" dir="rtl">{m.mark_text_ar}</div> : null}{m.mark_text_en ? <div lang="en" dir="ltr">{m.mark_text_en}</div> : null}{!m.mark_text_ar && !m.mark_text_en ? "—" : null}
            {m.mark_type ? <div className="ms-cap">{m.mark_type}</div> : null}
            {m.has_image ? <div className="ms-cap">{t("ops.reading.image")}{m.image_description ? `: ${m.image_description}` : ""}</div> : null}
            {m.mark_meaning_t ? <div className="ms-cap">{t("ops.reading.meaning", { text: m.mark_meaning_t })}</div> : null}
            {m.goods ? <div className="ms-cap" dir="auto">{m.goods.length > 220 ? `${m.goods.slice(0, 220)} …` : m.goods}</div> : null}{m.goods_t ? <div className="ms-cap tr-line" dir="auto">{m.goods_t}</div> : null}</div></td>
          <td className="num">{(m.classes ?? []).join(", ") || "—"}</td>
          <td className="ops-wraps"><div className="ops-cell"><span dir="auto">{m.applicant_name ?? "—"}</span>{m.applicant_country ? <span className="ms-cap num"> · {m.applicant_country}</span> : null}{m.applicant_name_t ? <div className="ms-cap tr-line" dir="auto">{m.applicant_name_t}</div> : null}</div></td>
          <td className="ops-wraps"><div className="ops-cell"><span dir="auto">{m.agent_name ?? "—"}</span>{m.agent_city ? <span className="ms-cap"> · {m.agent_city}</span> : null}{m.agent_name_t ? <div className="ms-cap tr-line" dir="auto">{m.agent_name_t}</div> : null}</div></td>
          <td className="num">{typeof m.confidence === "number" ? `${Math.round(m.confidence * 100)}%` : "—"}</td>
          {state ? <td><span className={m.verify_state === "ai_extracted" ? "flag flag-amber" : "flag flag-green"}>{t(`ops.reading.verify.${m.verify_state ?? "ai_extracted"}`)}</span></td> : null}
        </tr>
      ))}
    </Table></div>
  );
}
