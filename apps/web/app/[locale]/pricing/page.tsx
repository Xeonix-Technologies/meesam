import Link from "next/link";
import { notFound } from "next/navigation";
import { formatDate, isLocale, translator } from "@meesam/i18n";
import { AuthShell } from "@/components/AuthShell";
import { publicPrices } from "@/lib/public";

export const dynamic = "force-dynamic";

/**
 * Public Pricing page (Founder ruling R10, 21 Nov 2026): the list price and the introductory price, with the
 * VAT-inclusive figure for the UAE. Every figure comes from the price list in force (configuration), never from
 * this file. Open points are said as open: renewal price, the end of the introductory offer, pilot terms.
 */
export default async function Pricing({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const p = await publicPrices();
  const money = (n: number) => `${p.currency} ${Number.isInteger(n) ? n : n.toFixed(2)}`;
  const withVat = (n: number) => money(Math.round(n * (1 + p.vatRate) * 100) / 100);
  const vatPct = Math.round(p.vatRate * 100);
  return (
    <AuthShell locale={locale} path="/pricing" title={t("pricing.title")} wide>
      <p className="home-lead">{t("pricing.lead")}</p>
      {p.pilotFree ? <div className="ms-note ms-note--ok" role="note"><div><div className="ms-note__t">{t("pricing.pilotTitle")}</div><div>{t("pricing.pilotBody")}</div></div></div> : null}

      <h2>{t("pricing.registered.title")}</h2>
      <p>{t("pricing.registered.body", { years: p.baseYears })}</p>
      <div className="legal-table"><table>
        <thead><tr><th scope="col">{t("pricing.cols.years")}</th><th scope="col">{t("pricing.cols.list")}</th>{p.introductoryOpen ? <th scope="col">{t("pricing.cols.intro")}</th> : null}<th scope="col">{t("pricing.cols.vat", { pct: vatPct })}</th></tr></thead>
        <tbody>{p.steps.map((s) => (
          <tr key={s.years}>
            <td>{s.years === p.floorYears ? t("pricing.yearsOrLess", { n: s.years }) : t("pricing.yearsN", { n: s.years })}</td>
            <td className="num">{money(s.list)}</td>
            {p.introductoryOpen ? <td className="num"><strong>{money(s.introductory)}</strong></td> : null}
            <td className="num">{withVat(p.introductoryOpen ? s.introductory : s.list)}</td>
          </tr>))}</tbody>
      </table></div>
      <p className="muted small">{t("pricing.vatNote", { pct: vatPct })}</p>
      {p.introductoryOpen ? <p>{p.introductoryUntil ? t("pricing.introUntil", { date: formatDate(p.introductoryUntil, locale) }) : t("pricing.introOpen")}</p> : null}

      {p.filingFee !== null ? (<>
        <h2>{t("pricing.newMark.title")}</h2>
        <p>{t("pricing.newMark.body", { fee: money(p.filingFee) })} {p.filingFeeCredited ? t("pricing.newMark.credited") : ""} {p.filingFeeRefundable ? "" : t("pricing.newMark.notRefunded")}</p>
      </>) : null}

      <h2>{t("pricing.more.title")}</h2>
      <ul>
        {p.extraRegistry !== null ? <li>{t("pricing.more.registry", { price: money(p.extraRegistry) })}</li> : null}
        {p.classAdd !== null ? <li>{t("pricing.more.classAdd", { price: money(p.classAdd) })}</li> : null}
        <li>{p.renewalPrice !== null ? t("pricing.more.renewal", { price: money(p.renewalPrice) }) : t("pricing.more.renewalOpen")}</li>
      </ul>

      <h2>{t("pricing.covers.title")}</h2>
      <p>{t("pricing.covers.body")}</p>
      <p className="muted small">{t("pricing.listNote", { name: p.name ?? "—", date: p.effectiveFrom ? formatDate(p.effectiveFrom, locale) : "—" })}</p>
      <p><Link href={`/${locale}/create-account`} className="ms-btn">{t("pricing.start")}</Link> <Link href={`/${locale}/help`}>{t("help.title")}</Link></p>
    </AuthShell>
  );
}
