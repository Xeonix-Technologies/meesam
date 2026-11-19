import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { listInstructionInvites, listInstructions, type InstructionRow } from "@/lib/instructions";
import { Empty, MarkName, PageHead, Panel } from "@/components/ms";
import { COUNTRIES } from "@/components/countries";
import { OtherAccount } from "@/components/OtherAccount";

export const dynamic = "force-dynamic";

/** Agency → Cross-border instructions: received from and sent to other offices (Agency Services 3.11). */
export default async function Instructions({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string; for?: string }> }) {
  const { locale } = await params;
  const { saved, error, for: forAccount } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  if (forAccount && forAccount !== session.accountId) return <OtherAccount locale={locale} name={pickText(session.accountName, locale) || session.userName} email={session.email} />;
  const t = translator(locale);
  // an owner sees the instructions it sent (ruling 19 Nov 2026); an agency office also those it received
  const isAgency = session.accountKind === "agency_office";
  const isAdmin = session.role === (isAgency ? "agency_admin" : "company_admin");
  const canAnswer = isAgency && (session.role === "agency_admin" || session.role === "agent");
  const [all, invites] = await Promise.all([listInstructions(session), listInstructionInvites(session)]);
  const country = (code: string | null) => { const c = COUNTRIES.find((x) => x.code === code); return c ? (locale === "ar" ? c.ar : c.en) : code ?? ""; };
  const incoming = all.filter((i) => i.status === "requested" && i.direction === "received");
  const waiting = all.filter((i) => i.status === "requested" && i.direction === "sent");
  const active = all.filter((i) => i.status === "active");
  const closed = all.filter((i) => i.status === "declined" || i.status === "ended");
  const hidden = (id: string) => <><input type="hidden" name="locale" value={locale} /><input type="hidden" name="instruction_id" value={id} /></>;
  const mark = (i: InstructionRow) => <><MarkName size="sm" runs={[i.mark_text?.ar, i.mark_text?.en]} /> <span className="ms-cap num">{i.registry_code} {i.number ?? ""}</span></>;
  const head = (i: InstructionRow) => (
    <div>
      <b>{pickText(i.other_name, locale)}</b> <span className="ms-cap">{country(i.other_country)}</span>
      <div>{mark(i)}</div>
      {i.owner_name ? <div className="ms-cap">{t("instructions.owner", { owner: pickText(i.owner_name, locale) })}</div> : null}
      {(i.legal_doc_name || i.poa_doc_name) && (i.direction === "sent" || i.status === "requested" || i.status === "active") ? (
        <div className="ms-row">
          {i.legal_doc_name ? <a href={`/api/instructions/${i.id}/doc?which=legal`} className="ms-link">{t("instructions.legalDoc")}</a> : null}
          {i.poa_doc_name ? <a href={`/api/instructions/${i.id}/doc?which=poa`} className="ms-link">{t("instructions.poaDoc")}</a> : null}
        </div>
      ) : null}
    </div>
  );

  return (
    <>
      <PageHead title={t("instructions.title")} sub={t(isAgency ? "instructions.sub" : "instructions.subOwner")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`instructions.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`instructions.errors.${error}`)}</div></div> : null}

      {isAgency ? <Panel title={`${t("instructions.toAnswer")} · ${incoming.length}`}>
        {incoming.length === 0 ? <p className="ms-sub">{t("instructions.noneToAnswer")}</p> : incoming.map((i) => (
          <div key={i.id} className="review-card">
            <div className="review-card__head">{head(i)}<div className="ms-cap">{t("links.requestedOn", { date: formatDate(i.created_at, locale) })}</div></div>
            {i.message ? <p className="ms-sub">“{i.message}”</p> : null}
            <p className="ms-cap">{t("instructions.acceptNote")}</p>
            {canAnswer ? (
              <form method="post" action="/api/instructions" className="form">
                {hidden(i.id)}
                <label className="ms-field"><span className="ms-field__l">{t("links.declineNote")}</span><input name="note" className="ms-input" maxLength={500} /></label>
                <div className="ms-row" style={{ justifyContent: "flex-end" }}>
                  <button type="submit" name="action" value="decline" className="ms-btn ms-btn--danger">{t("links.decline")}</button>
                  <button type="submit" name="action" value="accept" className="ms-btn">{t("links.accept")}</button>
                </div>
              </form>
            ) : null}
          </div>
        ))}
      </Panel> : null}

      <Panel title={`${t("instructions.inForce")} · ${active.length}`}>
        {active.length === 0 ? <Empty title={t("instructions.none")} body={t(isAgency ? "instructions.noneBody" : "instructions.noneBodyOwner")} /> : active.map((i) => (
          <div key={i.id} className="review-card">
            <div className="review-card__head">{head(i)}
              <span className={`ms-status ms-status--${i.in_force ? "progress" : "terminal"}`}><span className="ms-status__mark" aria-hidden="true" />{t(`instructions.direction.${i.direction}`)} · {t(`instructions.status.${i.in_force ? "active" : "notInForce"}`)}</span>
            </div>
            <div className="ms-row" style={{ justifyContent: "space-between" }}>
              {i.in_force || i.direction === "sent" ? <Link href={`/${locale}/records/${i.record_id}`} className="ms-link">{t("instructions.openRecord")}</Link> : <span className="ms-cap">{t("instructions.notInForceNote")}</span>}
              {isAdmin ? <form method="post" action="/api/instructions" className="inline">{hidden(i.id)}<button type="submit" name="action" value="end" className="ms-btn ms-btn--sm ms-btn--danger">{t("instructions.end")}</button></form> : null}
            </div>
          </div>
        ))}
      </Panel>

      {waiting.length ? (
        <Panel title={t("instructions.sentWaiting")}>
          {waiting.map((i) => (
            <div key={i.id} className="ag-line"><span><b>{pickText(i.other_name, locale)}</b> {mark(i)} <span className="ms-cap">{t("links.requestedOn", { date: formatDate(i.created_at, locale) })}</span></span>
              {isAdmin ? <form method="post" action="/api/instructions" className="inline">{hidden(i.id)}<button type="submit" name="action" value="end" className="ms-btn ms-btn--sm ms-btn--quiet">{t("instructions.withdraw")}</button></form> : null}</div>
          ))}
        </Panel>
      ) : null}

      {invites.length ? (
        <Panel title={t("instructions.invitesTitle")}>
          {invites.map((v) => (
            <div key={v.id} className="ag-line"><span><b dir="ltr">{v.email}</b> <MarkName size="sm" runs={[v.mark_text?.ar, v.mark_text?.en]} /> <span className="ms-cap num">{v.registry_code} {v.number ?? ""}</span> <span className="ms-cap">{t("links.clients.invitedOn", { date: formatDate(v.created_at, locale) })}</span></span>
              <form method="post" action="/api/instructions" className="inline"><input type="hidden" name="locale" value={locale} /><input type="hidden" name="invite_id" value={v.id} /><button type="submit" name="action" value="withdraw_invite" className="ms-btn ms-btn--sm ms-btn--quiet">{t("instructions.withdraw")}</button></form></div>
          ))}
        </Panel>
      ) : null}

      {closed.length ? (
        <Panel title={t("instructions.history")}>
          {closed.map((i) => (
            <div key={i.id} className="ag-line"><span><b>{pickText(i.other_name, locale)}</b> {mark(i)} <span className="ms-cap">{t(`instructions.direction.${i.direction}`)} · {t(`instructions.status.${i.status}`)}{i.ended_at ? ` · ${formatDate(i.ended_at, locale)}` : ""}{i.decline_note ? ` · “${i.decline_note}”` : ""}</span></span></div>
          ))}
        </Panel>
      ) : null}
    </>
  );
}
