import { notFound } from "next/navigation";
import { formatDateTime, isLocale, pickText, translator } from "@meesam/i18n";
import { listHeldCorrections, readerUsage } from "@/lib/staff";
import { Empty, PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/**
 * System Admin → Certificates (Founder ruling 28 Nov 2026; migration 0113). A correction of what Meesam read from a
 * certificate that the certificate or the registry's publication did not bear out is held here until an
 * administrator settles it: accepted (the reading carries the corrected value and the account confirms) or rejected.
 * Below it, what the certificate reader has used, for the cost report.
 */
export default async function AdminCertificates({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const [held, usage] = await Promise.all([listHeldCorrections(), readerUsage()]);
  const n = (v: number) => new Intl.NumberFormat(locale).format(v);
  return (
    <>
      <PageHead title={t("admin.certificates.title")} sub={t("admin.certificates.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`admin.certificates.saved.${saved === "accepted" ? "accepted" : "rejected"}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`admin.certificates.errors.${error === "noteRequired" ? "noteRequired" : "generic"}`)}</div></div> : null}

      <Panel title={`${t("admin.certificates.held")} · ${held.length}`}>
        {held.length === 0 ? <Empty title={t("admin.certificates.none")} /> : held.map((c) => (
          <div key={c.id} className="review-card">
            <div className="review-card__head">
              <div><b dir="auto">{pickText(c.mark_text, locale) || "—"}</b> <span className="ms-cap"><span className="num">{c.registry_code}</span> · <span className="num">{c.number ?? "—"}</span></span>
                <div className="ms-cap">{pickText(c.account, locale)} · {c.user_name} <span className="num">{c.user_email}</span> · {formatDateTime(c.created_at, locale)}</div></div>
              <div><a className="ms-link" href={`/api/admin/certificates?file=${c.id}`}>{t("admin.certificates.open")}</a></div>
            </div>
            <dl className="ms-kv">
              <dt>{t("admin.certificates.field")}</dt><dd>{t(`record.certConfirm.fields.${c.field}`)}</dd>
              <dt>{t("admin.certificates.read")}</dt><dd dir="auto">{c.certificate_value ?? "—"}</dd>
              <dt>{t("admin.certificates.corrected")}</dt><dd dir="auto"><b>{c.corrected_value}</b></dd>
              <dt>{t("admin.certificates.certificateSays")}</dt><dd>{t(`admin.certificates.check.${c.certificate_check ?? "unclear"}`)}{c.certificate_passage ? <div className="ms-cap" dir="auto">“{c.certificate_passage}”</div> : null}</dd>
              <dt>{t("admin.certificates.publicationSays")}</dt><dd>{t(`admin.certificates.check.${c.published_check ?? "none"}`)}{c.published_value ? <div className="ms-cap" dir="auto">{c.published_value}</div> : null}</dd>
            </dl>
            <form method="post" action="/api/admin/certificates" className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="correction_id" value={c.id} />
              <label className="ms-field"><span className="ms-field__l">{t("admin.certificates.note")}</span><input name="note" className="ms-input" maxLength={300} /></label>
              <div className="ms-row" style={{ justifyContent: "flex-end" }}>
                <button type="submit" name="decision" value="reject" className="ms-btn ms-btn--danger">{t("admin.certificates.reject")}</button>
                <button type="submit" name="decision" value="accept" className="ms-btn">{t("admin.certificates.accept")}</button>
              </div>
            </form>
          </div>
        ))}
      </Panel>

      <Panel title={t("admin.certificates.usage")}>
        <p className="ms-cap">{t("admin.certificates.usageNote")}</p>
        {usage.length === 0 ? <p className="ms-sub">{t("admin.certificates.usageNone")}</p> : (
          <div className="ops-table"><Table head={[t("admin.certificates.u.month"), t("admin.certificates.u.model"), t("admin.certificates.u.readings"), t("admin.certificates.u.checks"), t("admin.certificates.u.input"), t("admin.certificates.u.output")]}>
            {usage.map((u) => (
              <tr key={`${u.month}:${u.model}`}>
                <td className="num">{u.month.slice(0, 7)}</td><td dir="ltr">{u.model ?? "—"}</td>
                <td className="num">{n(u.readings)}</td><td className="num">{n(u.checks)}</td><td className="num">{n(u.input_tokens)}</td><td className="num">{n(u.output_tokens)}</td>
              </tr>
            ))}
          </Table></div>
        )}
      </Panel>
    </>
  );
}
