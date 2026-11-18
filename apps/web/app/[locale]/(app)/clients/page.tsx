import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { listAppointments, type AppointmentRow } from "@/lib/appointments";
import { Empty, MarkName, PageHead, Panel } from "@/components/ms";
import { COUNTRIES } from "@/components/countries";
import { OtherAccount } from "@/components/OtherAccount";

export const dynamic = "force-dynamic";

/** Agency → Clients: appointment requests to answer and the owners this office acts for (Agency Services, client list). */
export default async function Clients({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string; for?: string }> }) {
  const { locale } = await params;
  const { saved, error, for: forAccount } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  // a link from an e-mail names the account it was sent to; if another account is signed in here, say so
  if (forAccount && forAccount !== session.accountId) return <OtherAccount locale={locale} name={pickText(session.accountName, locale) || session.userName} email={session.email} />;
  if (session.accountKind !== "agency_office") redirect(`/${locale}/agencies`);
  const t = translator(locale);
  // Founder ruling 18 Nov 2026: an Agent answers appointment requests as the administrator does; ending stays with the administrator
  const canEnd = session.role === "agency_admin";
  const canAnswer = canEnd || session.role === "agent";
  const appointments = await listAppointments(session);
  const country = (code: string | null) => { const c = COUNTRIES.find((x) => x.code === code); return c ? (locale === "ar" ? c.ar : c.en) : code ?? ""; };
  const incoming = appointments.filter((a) => a.status === "requested" && a.requested_by === "owner");
  const sent = appointments.filter((a) => a.status === "requested" && a.requested_by === "agency");
  const clients = appointments.filter((a) => a.status === "accepted");
  const closed = appointments.filter((a) => a.status === "declined" || a.status === "ended");
  const hidden = (action: string | null, id: string) => <><input type="hidden" name="locale" value={locale} />{action ? <input type="hidden" name="action" value={action} /> : null}<input type="hidden" name="appointment_id" value={id} /></>;
  const recordList = (a: AppointmentRow) => (a.records ?? []).length ? (
    <div className="record-picks">{(a.records ?? []).map((r) => {
      const name = <><MarkName size="sm" runs={[r.mark_text?.ar, r.mark_text?.en]} /> <span className="ms-cap num">{r.registry_code} {r.number ?? ""}</span></>;
      return <Link key={r.id} href={`/${locale}/records/${r.id}`} className="ms-link check">{name}</Link>;
    })}</div>
  ) : <p className="ms-cap">{t("links.clients.noRecords")}</p>;

  return (
    <>
      <PageHead title={t("links.clients.title")} sub={t("links.clients.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`links.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`links.errors.${error}`)}</div></div> : null}

      <Panel title={`${t("links.clients.requests")} · ${incoming.length}`}>
        {incoming.length === 0 ? <p className="ms-sub">{t("links.clients.noRequests")}</p> : incoming.map((a) => (
          <div key={a.id} className="review-card">
            <div className="review-card__head">
              <div><b>{pickText(a.other_name, locale)}</b> <span className="ms-cap">{country(a.other_country)}{a.other_city ? ` · ${a.other_city}` : ""}</span>
                <div className="ms-cap">{t("links.requestedOn", { date: formatDate(a.requested_at, locale) })}</div></div>
            </div>
            {a.message ? <p className="ms-sub">“{a.message}”</p> : null}
            <p className="ms-cap">{t("links.clients.recordsOffered", { n: a.record_count })}</p>
            {canAnswer ? (
              <form method="post" action="/api/appointments" className="form">
                {hidden(null, a.id)}
                <label className="ms-field"><span className="ms-field__l">{t("links.declineNote")}</span><input name="note" className="ms-input" maxLength={500} /></label>
                <div className="ms-row" style={{ justifyContent: "flex-end" }}>
                  <button type="submit" name="action" value="decline" className="ms-btn ms-btn--danger">{t("links.decline")}</button>
                  <button type="submit" name="action" value="accept" className="ms-btn">{t("links.accept")}</button>
                </div>
              </form>
            ) : <p className="ms-cap">{t("links.clients.adminAnswers")}</p>}
          </div>
        ))}
      </Panel>

      <Panel title={`${t("links.clients.list")} · ${clients.length}`}>
        {clients.length === 0 ? <Empty title={t("links.clients.none")} body={t("links.clients.noneBody")} /> : clients.map((a) => (
          <div key={a.id} className="review-card">
            <div className="review-card__head">
              <div><b>{pickText(a.other_name, locale)}</b> <span className="ms-cap">{country(a.other_country)}{a.other_city ? ` · ${a.other_city}` : ""}</span>
                <div className="ms-cap">{t("links.since", { date: formatDate(a.accepted_at ?? a.requested_at, locale) })}</div></div>
              <span className="ms-status ms-status--progress"><span className="ms-status__mark" aria-hidden="true" />{t("links.status.accepted")}</span>
            </div>
            {recordList(a)}
            {canEnd ? (
              <form method="post" action="/api/appointments" className="form">
                {hidden("end", a.id)}
                <div className="ms-row" style={{ justifyContent: "space-between" }}><span className="ms-cap">{t("links.endNoteAgency")}</span><button type="submit" className="ms-btn ms-btn--danger">{t("links.end")}</button></div>
              </form>
            ) : null}
          </div>
        ))}
      </Panel>

      {sent.length ? (
        <Panel title={t("links.clients.sent")}>
          {sent.map((a) => (
            <div key={a.id} className="ag-line"><span><b>{pickText(a.other_name, locale)}</b> <span className="ms-cap">{t("links.requestedOn", { date: formatDate(a.requested_at, locale) })}</span></span>
              <form method="post" action="/api/appointments" className="inline">{hidden("end", a.id)}<button type="submit" className="ms-btn ms-btn--sm ms-btn--quiet">{t("links.withdraw")}</button></form></div>
          ))}
        </Panel>
      ) : null}

      {closed.length ? (
        <Panel title={t("links.history")}>
          {closed.map((a) => (
            <div key={a.id} className="ag-line"><span><b>{pickText(a.other_name, locale)}</b> <span className="ms-cap">{t(`links.status.${a.status}`)}{a.ended_at ? ` · ${formatDate(a.ended_at, locale)}` : ""}{a.decline_note ? ` · “${a.decline_note}”` : ""}</span></span></div>
          ))}
        </Panel>
      ) : null}
    </>
  );
}
