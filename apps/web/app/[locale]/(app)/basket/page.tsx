import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatMoney, isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { activationCounts, basket } from "@/lib/basket";
import { Btn, Empty, MarkName, PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/**
 * Basket (Founder ruling 27 Nov 2026): the trademarks loaded in bulk for which activation was requested, each with
 * today's price from the price list in force, and one checkout for all of them. While the pilot is free nothing is
 * due; outside the pilot payment is not connected yet and the basket says so.
 */
export default async function Basket({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string; added?: string; activated?: string }> }) {
  const { locale } = await params;
  const { saved, error, added, activated } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const [{ lines, free }, counts] = await Promise.all([basket(session), activationCounts(session)]);
  const canAct = session.role !== "viewer";
  const money = (v: string | number | null) => (v == null ? "—" : formatMoney(v, locale));
  const sum = (k: "due" | "vat" | "total") => lines.reduce((a, l) => a + Number(l[k] ?? 0), 0);
  const hidden = <input type="hidden" name="locale" value={locale} />;
  const n = (v?: string) => (v && /^\d+$/.test(v) ? Number(v) : 0);

  return (
    <>
      <PageHead title={t("basket.title")} sub={t("basket.sub")} />
      {n(activated) ? <div className="ms-note ms-note--ok" role="status"><div><div className="ms-note__t">{t("basket.activatedN", { n: n(activated) })}</div><div>{t("basket.activatedNote")}</div></div></div> : null}
      {n(added) ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("basket.addedN", { n: n(added) })}</div></div> : null}
      {saved === "takenOut" ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("basket.takenOut")}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`basket.errors.${["notReady", "noneReady", "empty", "notAllowed", "paymentClosed"].includes(error) ? error : "generic"}`)}</div></div> : null}

      {counts.waiting > 0 ? (
        <Panel title={t("basket.waitingTitle", { n: counts.waiting })}>
          <p className="ms-sub">{t("basket.waitingBody", { ready: counts.ready, missing: counts.waiting - counts.ready })}</p>
          <div className="ms-row" style={{ justifyContent: "space-between" }}>
            <Link href={`/${locale}/records?paid=not_active`} className="ms-link">{t("basket.seeWaiting")}</Link>
            {canAct && counts.ready > 0 ? (
              <form method="post" action="/api/basket">{hidden}<button type="submit" name="action" value="request_ready" className="ms-btn ms-btn--quiet">{t("basket.addReady", { n: counts.ready })}</button></form>
            ) : null}
          </div>
        </Panel>
      ) : null}

      {lines.length === 0 ? (
        <Empty title={t("basket.emptyTitle")} body={t("basket.emptyBody")} actions={<Btn href={`/${locale}/records`} quiet>{t("dashboard.openPortfolio")}</Btn>} />
      ) : (
        <Panel title={t("basket.linesTitle", { n: lines.length })}>
          <Table head={[t("portfolio.cols.mark"), t("portfolio.cols.registry"), ...(session.accountKind === "agency_office" ? [t("portfolio.cols.client")] : []), t("record.fee.yearsRemaining"), t("record.fee.price"), ""]}>
            {lines.map((l) => (
              <tr key={l.record_id}>
                <td><Link href={`/${locale}/records/${l.record_id}`} className="ms-link"><MarkName size="sm" runs={[l.mark_text?.ar, l.mark_text?.en]} /></Link><div className="ms-cap num">{l.number ?? ""}</div></td>
                <td>{l.registry_code}</td>
                {session.accountKind === "agency_office" ? <td>{l.client ?? "—"}</td> : null}
                <td className="num">{l.years_remaining ?? "—"}</td>
                <td className="num">{money(l.amount)}{l.introductory ? <div className="ms-cap">{t("record.fee.introductory")}</div> : null}</td>
                <td>{canAct ? <form method="post" action="/api/basket">{hidden}<input type="hidden" name="record_id" value={l.record_id} /><button type="submit" name="action" value="withdraw" className="ms-btn ms-btn--quiet ms-btn--sm">{t("basket.takeOut")}</button></form> : null}</td>
              </tr>
            ))}
          </Table>
          <dl className="ms-kv">
            <dt>{t("basket.listTotal")}</dt><dd className="num">{money(sum("due"))}</dd>
            <dt>{t("record.fee.vat")}</dt><dd className="num">{money(sum("vat"))}</dd>
            <dt>{t("record.fee.total")}</dt><dd className="num">{money(sum("total"))}</dd>
            {free ? <><dt>{t("basket.dueNow")}</dt><dd className="num"><strong>{money(0)}</strong></dd></> : null}
          </dl>
          <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t(free ? "record.fee.pilot" : "basket.paymentClosedTitle")}</div><div>{t(free ? "basket.pilotNote" : "basket.errors.paymentClosed")}</div></div></div>
          {canAct && free ? (
            <form method="post" action="/api/basket" className="form">{hidden}
              <div className="ms-row" style={{ justifyContent: "flex-end" }}><button type="submit" name="action" value="checkout" className="ms-btn">{t("basket.activate", { n: lines.length })}</button></div>
            </form>
          ) : null}
          {!canAct ? <p className="ms-cap">{t("basket.errors.notAllowed")}</p> : null}
        </Panel>
      )}
    </>
  );
}
