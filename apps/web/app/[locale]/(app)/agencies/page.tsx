import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { listAppointments, listDirectory, type AppointmentRow } from "@/lib/appointments";
import { listPortfolio } from "@/lib/records";
import { Empty, MarkName, PageHead, Panel } from "@/components/ms";
import { COUNTRIES } from "@/components/countries";
import { OtherAccount } from "@/components/OtherAccount";

export const dynamic = "force-dynamic";

/** Owner → Agencies: the agencies acting for this account, requests in progress, and Meesam's directory (4.4 link 1). */
export default async function Agencies({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string; for?: string }> }) {
  const { locale } = await params;
  const { saved, error, for: forAccount } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  // a link from an e-mail names the account it was sent to; if another account is signed in here, say so
  if (forAccount && forAccount !== session.accountId) return <OtherAccount locale={locale} name={pickText(session.accountName, locale) || session.userName} email={session.email} />;
  if (session.accountKind === "agency_office") redirect(`/${locale}/clients`);
  const t = translator(locale);
  const [appointments, directory, records] = await Promise.all([listAppointments(session), listDirectory(session), listPortfolio(session)]);
  const own = records;
  const country = (code: string | null) => { const c = COUNTRIES.find((x) => x.code === code); return c ? (locale === "ar" ? c.ar : c.en) : code ?? ""; };
  const open = appointments.filter((a) => a.status === "requested" || a.status === "accepted");
  const closed = appointments.filter((a) => a.status === "declined" || a.status === "ended");
  const openWith = new Set(open.map((a) => a.agency_account_id));
  const tone = (a: AppointmentRow) => (a.status === "accepted" ? "progress" : a.status === "requested" ? (a.requested_by === "agency" ? "user" : "registry") : "terminal");
  const recordChecks = (checked: Set<string> | "all") => (
    <div className="record-picks">
      {own.map((r) => (
        <label key={r.record_id} className="check"><input type="checkbox" name="record_id" value={r.record_id} defaultChecked={checked === "all" || checked.has(r.record_id)} />
          <MarkName size="sm" runs={[r.mark_text?.ar, r.mark_text?.en]} /> <span className="ms-cap num">{r.registry_code} {r.registration_no ?? r.application_no ?? ""}</span></label>
      ))}
    </div>
  );
  // forms with two buttons carry the action on the button pressed, so no hidden action there
  const hidden = (action: string | null, id?: string) => <><input type="hidden" name="locale" value={locale} />{action ? <input type="hidden" name="action" value={action} /> : null}{id ? <input type="hidden" name="appointment_id" value={id} /> : null}</>;

  return (
    <>
      <PageHead title={t("links.agencies.title")} sub={t("links.agencies.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`links.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`links.errors.${error}`)}</div></div> : null}

      <Panel title={t("links.agencies.yours")}>
        {open.length === 0 ? <Empty title={t("links.agencies.none")} body={t("links.agencies.noneBody")} /> : open.map((a) => (
          <div key={a.id} className="review-card">
            <div className="review-card__head">
              <div><b>{pickText(a.other_name, locale)}</b> <span className="ms-cap">{country(a.other_country)}{a.other_city ? ` · ${a.other_city}` : ""}</span>
                <div className="ms-cap">{a.status === "accepted" ? t("links.since", { date: formatDate(a.accepted_at ?? a.requested_at, locale) }) : t("links.requestedOn", { date: formatDate(a.requested_at, locale) })}</div></div>
              <span className={`ms-status ms-status--${tone(a)}`}><span className="ms-status__mark" aria-hidden="true" />{t(`links.status.${a.status}${a.status === "requested" ? (a.requested_by === "agency" ? "ByThem" : "ByYou") : ""}`)}</span>
            </div>
            {a.message ? <p className="ms-sub">“{a.message}”</p> : null}
            {a.status === "requested" && a.requested_by === "agency" ? (
              <form method="post" action="/api/appointments" className="form">
                {hidden(null, a.id)}
                {own.length === 0 ? (
                  <p className="ms-sub">{t("links.agencies.acceptEmpty")}</p>
                ) : <><span className="ms-field__l">{t("links.agencies.chooseRecords")}</span>{recordChecks("all")}</>}
                <label className="ms-field"><span className="ms-field__l">{t("links.declineNote")}</span><input name="note" className="ms-input" maxLength={500} /></label>
                <div className="ms-row" style={{ justifyContent: "flex-end" }}>
                  <button type="submit" name="action" value="decline" className="ms-btn ms-btn--danger" formNoValidate>{t("links.decline")}</button>
                  <button type="submit" name="action" value="accept" className="ms-btn">{t("links.accept")}</button>
                </div>
              </form>
            ) : (
              <form method="post" action="/api/appointments" className="form">
                {hidden(null, a.id)}
                {own.length === 0 ? (
                  <div className="ms-note ms-note--warn" role="status"><div className="ms-note__t">{t("links.agencies.noneYet")}</div><div><Link href={`/${locale}/records/new`} className="ms-link">{t("dashboard.actions.addExisting")}</Link></div></div>
                ) : <><span className="ms-field__l">{t("links.agencies.recordsCovered")}</span>{recordChecks(new Set((a.records ?? []).map((r) => r.id)))}
                  {a.status === "accepted" && (a.records ?? []).length === 0 ? <p className="ms-cap">{t("links.agencies.chooseNow")}</p> : null}</>}
                <div className="ms-row" style={{ justifyContent: "space-between" }}>
                  <button type="submit" name="action" value="end" className="ms-btn ms-btn--danger" formNoValidate>{a.status === "accepted" ? t("links.end") : t("links.withdraw")}</button>
                  {own.length ? <button type="submit" name="action" value="scope" className="ms-btn ms-btn--quiet">{t("links.agencies.saveRecords")}</button> : null}
                </div>
                {a.status === "accepted" ? <p className="ms-cap">{t("links.endNote")}</p> : null}
              </form>
            )}
          </div>
        ))}
      </Panel>

      <Panel title={t("links.agencies.directory")} sub={t("links.agencies.directorySub")}>
        {directory.length === 0 ? <Empty title={t("links.agencies.directoryEmpty")} body={t("links.agencies.directoryEmptyBody")} /> : directory.map((d) => (
          <details key={d.id} className="review-card">
            <summary className="review-card__head">
              <div><b>{pickText(d.name, locale)}</b> <span className="ms-cap">{country(d.country)}{d.city ? ` · ${d.city}` : ""}</span>
                {d.contact?.website ? <div className="ms-cap num">{d.contact.website}</div> : null}</div>
              <span className="ms-btn ms-btn--quiet ms-btn--sm">{openWith.has(d.id) ? t("links.agencies.alreadyOpen") : t("links.agencies.appoint")}</span>
            </summary>
            {openWith.has(d.id) ? null : own.length === 0 ? <p className="ms-sub">{t("links.agencies.needRecord")}</p> : (
              <form method="post" action="/api/appointments" className="form">
                {hidden("request")}<input type="hidden" name="account_id" value={d.id} />
                <span className="ms-field__l">{t("links.agencies.chooseRecords")}</span>
                {recordChecks("all")}
                <label className="ms-field"><span className="ms-field__l">{t("links.message")}</span><textarea name="message" rows={3} maxLength={1000} className="ms-input" /></label>
                <div className="ms-row" style={{ justifyContent: "flex-end" }}><button type="submit" className="ms-btn">{t("links.agencies.send")}</button></div>
              </form>
            )}
          </details>
        ))}
      </Panel>

      <Panel title={t("pass.panelTitle")} sub={t("pass.panelSub")}>
        <form method="get" action={`/${locale}/pass`} className="ms-row">
          <input name="code" required dir="ltr" autoComplete="off" placeholder="XXXX-XXXX-XXXX" className="ms-input" style={{ maxWidth: 240 }} aria-label={t("pass.code")} />
          <button type="submit" className="ms-btn ms-btn--quiet">{t("pass.check")}</button>
        </form>
      </Panel>

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
