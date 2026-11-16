import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";
import { timerLabel, daysUntil } from "@/lib/timers";
import { getRecord } from "@/lib/records";
import { DOC_TYPES } from "@/lib/upload";
import { Field } from "@/components/Field";

export const dynamic = "force-dynamic";

const STAGES = ["pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration", "renewal_grace_expiry"] as const;
const SIDE_STAGES = ["post_registration_recordals", "challenges", "enforcement"] as const;
const TABS = ["overview", "mark", "certificate", "documents", "timeline", "agencies", "watch", "fee"] as const;
/** Timer labels: statutory clocks by name; reminders as "<clock> reminder, N months before". */
const EVENTS = ["accepted", "office_action", "response_filed", "published", "opposed", "appealed", "registered", "declaration_of_use", "recordal", "renewed", "challenged", "enforcement", "refused", "withdrawn", "cancelled", "expired"];

/** Trademark record (Owner 3.4 / Agency 3.4), laid out per item 37 as amended by item 42. */
export default async function RecordPage({ params, searchParams }: { params: Promise<{ locale: string; id: string }>; searchParams: Promise<{ tab?: string; error?: string; saved?: string; created?: string }> }) {
  const { locale, id } = await params;
  const { tab: tabRaw, error, saved, created } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const r = await getRecord(session, id);
  if (!r) notFound();
  const t = translator(locale);
  const tab = (TABS as readonly string[]).includes(tabRaw ?? "") ? (tabRaw as (typeof TABS)[number]) : "overview";
  const title = pickText(r.mark_text, locale) || r.registration_no || r.application_no || t("record.untitled");
  // a power of attorney matters only when an agency acts on the record (self-managed marks need none)
  const poaRelevant = Boolean(r.holding_agency || r.agent_of_record);
  const openTimers = r.timers.filter((x) => x.state === "open");
  const openWarnings = (r.warnings ?? []).filter((w) => !w.confirmed_at);
  const price = r.paid_state !== "paid"
    ? ((await withAccount(db(), { accountId: session.accountId, userId: session.userId }, (tx) =>
        tx.execute(sql`SELECT * FROM core.fn_price(${r.entry_mode === "existing" ? "existing_watch" : "registration"}::core.payment_case, ${r.expiry_date}::date, current_date, false)`))) as unknown as Array<{ years_remaining: number; amount: string; vat: string }>)[0]
    : null;
  const stageIndex = (STAGES as readonly string[]).indexOf(r.stage);
  const tz = r.rules?.calendar.timezone ?? "UTC";
  const href = (x: string) => `/${locale}/records/${id}?tab=${x}`;
  const dateOrDash = (v: string | null | undefined) => (v ? formatDate(v, locale) : "—");

  return (
    <>
      {created ? <p className="notice">{t("record.created")}</p> : null}
      {saved ? <p className="notice">{t("common.saved")}</p> : null}
      {error ? <p className="error" role="alert">{t(`record.errors.${error}`)}</p> : null}

      <header className="record-head card">
        <div className="record-title">
          <h1>{title}</h1>
          <div className="muted">
            {r.mark_text?.ar && r.mark_text?.en ? <span>{r.mark_text.ar} · {r.mark_text.en} · </span> : null}
            {t(`intake.markTypes.${r.mark_type}`)} · {r.registry_code}
            {r.application_no ? <span dir="ltr"> · {t("intake.applicationNo")} {r.application_no}</span> : null}
            {r.registration_no ? <span dir="ltr"> · {t("intake.registrationNo")} {r.registration_no}</span> : null}
          </div>
          <div className="muted small">
            {t("portfolio.cols.managedBy")}: {r.holding_agency ? pickText(r.holding_agency, locale) : t("portfolio.self")}
            {r.agent_of_record ? ` · ${t("record.agentOfRecord")}: ${pickText(r.agent_of_record, locale)}` : ""}
            {" · "}{t(`record.paid.${r.paid_state}`)}
          </div>
        </div>
        <div className="flags">
          {poaRelevant && r.poa_state !== "present" ? <span className="flag flag-red">{t(`record.poa.${r.poa_state}`)}</span> : null}
          {openWarnings.length ? <span className="flag flag-amber">{t("record.flags.warningsN", { n: openWarnings.length })}</span> : null}
          {r.awaiting_deadline_entry ? <span className="flag flag-amber">{t("record.flags.deadline")}</span> : null}
          {r.terminal ? <span className="flag">{t("record.terminal")}</span> : null}
        </div>
      </header>

      <section className="card">
        <ol className="stage-bar nine">
          {STAGES.map((s, i) => <li key={s} className={i < stageIndex ? "done" : i === stageIndex ? "active" : ""}><span>{t(`stages.${s}`)}</span></li>)}
        </ol>
        <div className="side-stages muted small">
          {SIDE_STAGES.map((s) => <span key={s} className={r.stage === s ? "active" : ""}>{t(`stages.${s}`)}</span>)}
        </div>
        <p><strong>{r.status_label ? pickText(r.status_label, locale) : t(`stages.${r.stage}`)}</strong>
          {r.expiry_date ? <> · {t("timers.expiry")}: {formatDate(r.expiry_date, locale)}</> : null}
          {r.next_due_date ? <> · {t("record.nextDate")}: {timerLabel(t, r.next_timer_type)} — {formatDate(r.next_due_date, locale)} ({t("record.daysRemaining", { n: daysUntil(r.next_due_date) })})</> : null}
        </p>
      </section>

      <nav className="tabs">{TABS.map((x) => <Link key={x} href={href(x)} className={x === tab ? "active" : ""}>{t(`record.tabs.${x}`)}</Link>)}</nav>

      {tab === "overview" ? (
        <div className="grid-2">
          <section className="card">
            <h2>{t("record.nextDates")}</h2>
            {openTimers.length === 0 ? <p className="muted">{t("dashboard.none")}</p> : (
              <ul className="plain">
                {openTimers.map((x) => (
                  <li key={x.id}>
                    <strong>{timerLabel(t, x.timer_type)}</strong>{" — "}
                    {x.awaiting_user_entry ? (
                      <form method="post" action={`/api/records/${id}/timers`} className="inline">
                        <input type="hidden" name="locale" value={locale} /><input type="hidden" name="timer_id" value={x.id} />
                        <span className="muted small">{t("record.enterDeadline")}</span> <input type="date" name="due_date" required dir="ltr" /> <button className="button-secondary small" type="submit">{t("common.save")}</button>
                      </form>
                    ) : <>{formatDate(x.due_date!, locale)} <span className="muted small">({t("record.daysRemaining", { n: daysUntil(x.due_date!) })} · 23:59 {tz})</span></>}
                  </li>
                ))}
              </ul>
            )}
          </section>
          <section className="card">
            <h2>{t("record.madrid.title")}</h2>
            <p className="muted">{r.is_madrid ? JSON.stringify(r.madrid) : t("record.madrid.none")}</p>
            {openWarnings.length ? (
              <>
                <h2>{t("record.flags.warnings")}</h2>
                <ul className="plain">{openWarnings.map((w) => <li key={`${w.code}:${w.field}`}><strong>{t(`intake.fields.${w.field}`)}</strong>: {t(`checks.${w.code}`, w.params ?? {})}</li>)}</ul>
              </>
            ) : null}
          </section>
        </div>
      ) : null}

      {tab === "mark" ? (
        <section className="card">
          <h2>{t("record.tabs.mark")}</h2>
          <p>{r.mark_text?.ar ? <span lang="ar" dir="rtl">{r.mark_text.ar}</span> : null}{r.mark_text?.ar && r.mark_text?.en ? " · " : ""}{r.mark_text?.en ? <span lang="en" dir="ltr">{r.mark_text.en}</span> : null}</p>
          <table className="data"><thead><tr><th>{t("intake.classes")}</th><th>{t("record.heading")}</th><th>{t("intake.goods")}</th></tr></thead>
            <tbody>{r.classes.map((c) => <tr key={c.number}><td>{c.number}</td><td className="small">{pickText(c.heading, locale)}</td><td className="small">{c.terms?.map((x) => pickText(x, locale)).join("; ") ?? "—"}</td></tr>)}</tbody></table>
        </section>
      ) : null}

      {tab === "certificate" ? (
        <section className="card">
          <h2>{t("record.tabs.certificate")}</h2>
          <form method="post" action={`/api/records/${id}/certificate`} className="form">
            <input type="hidden" name="locale" value={locale} />
            <div className="grid-2">
              <Field label={t("intake.applicationNo")} name="application_no" required={false}><input id="application_no" name="application_no" dir="ltr" defaultValue={r.application_no ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.filingDate")} name="filing_date" required={false}><input id="filing_date" name="filing_date" type="date" dir="ltr" defaultValue={r.filing_date ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.registrationNo")} name="registration_no" required={false}><input id="registration_no" name="registration_no" dir="ltr" defaultValue={r.registration_no ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.registrationDate")} name="registration_date" required={false}><input id="registration_date" name="registration_date" type="date" dir="ltr" defaultValue={r.registration_date ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.expiryDate")} name="expiry_date" required={false}><input id="expiry_date" name="expiry_date" type="date" dir="ltr" defaultValue={r.expiry_date ?? ""} disabled={!r.can_edit} /></Field>
            </div>
            {r.can_edit ? <div className="actions"><span className="muted small">{t("record.certificateNote")}</span><button className="button" type="submit">{t("common.save")}</button></div> : <p className="muted small">{t("record.readOnly")}</p>}
          </form>
        </section>
      ) : null}

      {tab === "documents" ? (
        <section className="card">
          <h2>{t("record.tabs.documents")}</h2>
          {poaRelevant && r.poa_state !== "present" ? <p className="error">{t(`record.poa.${r.poa_state}`)}</p> : null}
          {r.documents.length === 0 ? <p className="muted">{t("dashboard.none")}</p> : (
            <table className="data"><thead><tr><th>{t("intake.documents.type")}</th><th>{t("record.file")}</th><th>{t("record.vaultName")}</th><th>{t("record.validUntil")}</th><th>{t("record.added")}</th></tr></thead>
              <tbody>{r.documents.map((dd) => (
                <tr key={dd.id}><td><span className="tag">{dd.doc_type}</span> {t(`docTypes.${dd.doc_type}`)}</td>
                  <td><a href={`/api/documents/${dd.id}`}>{dd.file_name}</a></td>
                  <td className="small" dir="ltr">{dd.object_key.split("/").pop()}</td>
                  <td>{dateOrDash(dd.valid_until)}</td><td>{formatDate(dd.created_at, locale)}</td></tr>
              ))}</tbody></table>
          )}
          {r.can_edit ? (
            <form method="post" action={`/api/records/${id}/documents`} encType="multipart/form-data" className="form upload-form">
              <input type="hidden" name="locale" value={locale} />
              <div className="grid-2">
                <Field label={t("intake.documents.type")} name="doc_type"><select id="doc_type" name="doc_type" defaultValue="ORC">{DOC_TYPES.map((c) => <option key={c} value={c}>{c} — {t(`docTypes.${c}`)}</option>)}</select></Field>
                <Field label={t("intake.documents.file")} name="file"><input id="file" name="file" type="file" accept=".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff" required /></Field>
                <Field label={t("record.validUntil")} name="valid_until" required={false} hint={t("record.validUntilHint")}><input id="valid_until" name="valid_until" type="date" dir="ltr" /></Field>
              </div>
              <div className="actions"><span /><button className="button-secondary" type="submit">{t("intake.documents.upload")}</button></div>
            </form>
          ) : null}
        </section>
      ) : null}

      {tab === "timeline" ? (
        <div className="grid-2">
          <section className="card">
            <h2>{t("record.tabs.timeline")}</h2>
            <ul className="timeline">
              {r.events.map((e) => (
                <li key={e.id}>
                  <span className="when">{formatDate(e.event_date, locale)}</span>
                  <strong>{t(`events.${e.event_type}`)}</strong>
                  {e.registry_status ? <span className="muted"> — {e.registry_status}</span> : null}
                  {e.source === "suggested" && !e.confirmed_at ? <span className="flag flag-amber">{t("record.flags.suggestion")}</span> : null}
                  <div className="muted small">{e.created_by_account ? pickText(e.created_by_account, locale) : "Meesam"} · {formatDate(e.created_at, locale)}</div>
                </li>
              ))}
            </ul>
            {r.edits.length ? <><h3 className="section-title">{t("record.edits")}</h3><ul className="plain small muted">{r.edits.slice(0, 15).map((e) => <li key={e.id}>{formatDate(e.created_at, locale)} · {e.table_name} · {e.account ? pickText(e.account, locale) : "—"}</li>)}</ul></> : null}
          </section>
          <section className="card">
            <h2>{t("record.stageChange.title")}</h2>
            {r.can_edit ? (
              <form method="post" action={`/api/records/${id}/events`} className="form">
                <input type="hidden" name="locale" value={locale} />
                <Field label={t("record.stageChange.event")} name="event_type"><select id="event_type" name="event_type" required>{EVENTS.map((e) => <option key={e} value={e}>{t(`events.${e}`)}</option>)}</select></Field>
                <div className="grid-2">
                  <Field label={t("record.stageChange.date")} name="event_date"><input id="event_date" name="event_date" type="date" required dir="ltr" /></Field>
                  <Field label={t("record.stageChange.number")} name="number" required={false}><input id="number" name="number" dir="ltr" /></Field>
                </div>
                <Field label={t("record.stageChange.registryStatus")} name="registry_status" required={false} hint={t("record.stageChange.registryStatusHint")}><input id="registry_status" name="registry_status" /></Field>
                <p className="muted small">{t("record.stageChange.note")}</p>
                <div className="actions"><span /><button className="button" type="submit">{t("record.stageChange.save")}</button></div>
              </form>
            ) : <p className="muted small">{t("record.readOnly")}</p>}
          </section>
        </div>
      ) : null}

      {tab === "agencies" ? (
        <section className="card"><h2>{t("record.tabs.agencies")}</h2>
          <p>{r.holding_agency ? t("record.heldBy", { name: pickText(r.holding_agency, locale) }) : t("record.noAgency")}</p>
          <p className="muted small">{t("record.agenciesLater")}</p></section>
      ) : null}

      {tab === "watch" ? (
        <section className="card"><h2>{t("record.tabs.watch")}</h2>
          <p>{r.watch_active ? t("record.watchOn") : t("record.watchOff")}</p>
          <p className="muted small">{t("record.watchLater")}</p></section>
      ) : null}

      {tab === "fee" ? (
        <section className="card"><h2>{t("record.tabs.fee")}</h2>
          <table className="review"><tbody>
            <tr><th>{t("record.fee.state")}</th><td>{t(`record.paid.${r.paid_state}`)}</td></tr>
            {price ? <>
              <tr><th>{t("record.fee.yearsRemaining")}</th><td>{price.years_remaining}</td></tr>
              <tr><th>{t("record.fee.price")}</th><td dir="ltr">AED {price.amount} + VAT {price.vat}</td></tr>
              <tr><th>{t("record.fee.pilot")}</th><td>{t("record.fee.pilotNote")}</td></tr>
            </> : null}
          </tbody></table>
          <p className="muted small">{t("record.fee.payLater")}</p></section>
      ) : null}
    </>
  );
}
