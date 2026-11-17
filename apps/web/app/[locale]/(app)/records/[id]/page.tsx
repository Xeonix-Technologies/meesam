import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";
import { timerLabel } from "@/lib/timers";
import { getRecord } from "@/lib/records";
import { DOC_TYPES } from "@/lib/upload";
import { Field } from "@/components/Field";
import { Btn, Due, Empty, MarkName, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/** The nine stages of item 42, in order; 6, 8 and 9 run beside a registered mark (event stages). */
const STAGES = [
  "pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration",
  "post_registration_recordals", "renewal_grace_expiry", "challenges", "enforcement",
] as const;
const EVENT_STAGES: Record<number, string> = { 6: "recordal", 8: "challenged", 9: "enforcement" };
const TABS = ["overview", "mark", "certificate", "documents", "timeline", "agencies", "watch", "fee"] as const;
const TABLE_NAMES: Record<string, true> = { record: true, record_class: true, record_event: true, document: true, timer: true, record_image: true };
const EVENTS = ["accepted", "office_action", "response_filed", "published", "opposed", "appealed", "registered", "declaration_of_use", "recordal", "renewed", "challenged", "enforcement", "refused", "withdrawn", "cancelled", "expired"];

/** Trademark record (Owner 3.4 / Agency 3.4; Pilot Prototype screen 4), laid out per item 37 as amended by item 42. */
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
  const poaRelevant = Boolean(r.holding_agency || r.agent_of_record);
  const openTimers = r.timers.filter((x) => x.state === "open");
  const openWarnings = (r.warnings ?? []).filter((w) => !w.confirmed_at);
  const price = r.paid_state !== "paid"
    ? ((await withAccount(db(), { accountId: session.accountId, userId: session.userId }, (tx) =>
        tx.execute(sql`SELECT * FROM core.fn_price(${r.entry_mode === "existing" ? "existing_watch" : "registration"}::core.payment_case, ${r.expiry_date}::date, current_date, false)`))) as unknown as Array<{ years_remaining: number; amount: string; vat: string }>)[0]
    : null;
  const tz = r.rules?.calendar.timezone ?? "UTC";
  const href = (x: string) => `/${locale}/records/${id}?tab=${x}`;
  const dateOrDash = (v: string | null | undefined) => (v ? formatDate(v, locale) : "—");
  const fmt = (v: string) => formatDate(v, locale);

  // stage bar state
  const current = (STAGES as readonly string[]).indexOf(r.stage) + 1; // 1..9
  const eventTypes = new Set(r.events.map((e) => e.event_type));
  const eventsOn = new Set<number>([6, 8, 9].filter((n) => eventTypes.has(EVENT_STAGES[n] ?? "")));
  const skipped = new Set<number>(current >= 5 && !eventTypes.has("appealed") ? [4] : []);
  const statusGroup = r.terminal ? "terminal" : r.awaiting_deadline_entry || r.has_suggestions ? "user" : "progress";
  const stageLabel = (n: number) => t(`stages.${STAGES[n - 1]}`);

  // timeline items: events plus audited edits, newest first
  const tl = [
    ...r.events.map((e) => ({ key: `e${e.id}`, date: e.event_date, sort: e.created_at, event: t(`events.${e.event_type}`) + (e.registry_status ? ` — ${e.registry_status}` : ""), by: e.created_by_account ? pickText(e.created_by_account, locale) : "Meesam", stage: true, pending: e.source === "suggested" && !e.confirmed_at })),
    ...r.edits.map((e) => ({ key: `x${e.id}`, date: e.created_at.slice(0, 10), sort: e.created_at, event: t("record.editOf", { table: TABLE_NAMES[e.table_name] ? t(`record.tables.${e.table_name}`) : e.table_name }), by: e.account ? pickText(e.account, locale) : "—", stage: false, pending: false })),
  ].sort((a, b) => (a.sort < b.sort ? 1 : -1));
  const Timeline = ({ items }: { items: typeof tl }) => (
    <ol className="ms-timeline">
      {items.map((it, i) => (
        <li key={it.key} className={`ms-tl${it.stage ? " is-stage" : ""}${i === 0 ? " is-latest" : ""}`}>
          <span className="ms-tl__date num">{fmt(it.date)}</span>
          <span className="ms-tl__rail"><span className="ms-tl__dot" /></span>
          <div><div className="ms-tl__event">{it.event}{it.pending ? <> <span className="ms-tag">{t("record.flags.suggestion")}</span></> : null}</div><div className="ms-tl__by">{it.by}</div></div>
        </li>
      ))}
    </ol>
  );

  const nextChip = r.next_due_date
    ? <Due t={t} what={timerLabel(t, r.next_timer_type)} date={r.next_due_date} dateLabel={fmt(r.next_due_date)} />
    : <Due t={t} what={r.awaiting_deadline_entry ? t("record.flags.deadline") : "—"} date={null} awaiting />;

  const managedBy = r.holding_agency ? pickText(r.holding_agency, locale) : t("portfolio.self");

  return (
    <>
      <div className="ms-row" style={{ justifyContent: "space-between" }}>
        <Link href={`/${locale}/records`} className="ms-link">{t("record.backToPortfolio")}</Link>
        <span className="ms-row">
          {r.can_edit ? <Btn href={`${href("timeline")}#stage-change`}>{t("record.stageChange.title")}</Btn> : null}
        </span>
      </div>

      {created ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("record.created")}</div></div> : null}
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("common.saved")}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`record.errors.${error}`)}</div></div> : null}
      {r.paid_state === "read_only_unpaid" ? <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.banners.unpaidTitle")}</div><div>{t("record.banners.unpaidBody")}</div></div></div> : null}
      {r.terminal ? <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.banners.closedTitle")}{r.status_label ? ` · ${pickText(r.status_label, locale)}` : ""}</div><div>{t("record.banners.closedBody")}</div></div></div> : null}

      <header className="ms-rh">
        <div className="ms-rh__top">
          <div className="ms-rh__id">
            <div className="ms-rh__eyebrow">
              <span>{pickText(r.registry_name, locale) || r.registry_code}</span>
              <span>{t(`intake.markTypes.${r.mark_type}`)}</span>
              {r.registration_no ? <span>{t("intake.registrationNo")} <span className="num">{r.registration_no}</span></span> : r.application_no ? <span>{t("intake.applicationNo")} <span className="num">{r.application_no}</span></span> : null}
              {r.classes.length ? <span>{t("intake.classes")} <span className="num">{r.classes.map((c) => c.number).join(", ")}</span></span> : null}
            </div>
            <MarkName as="h1" runs={[r.mark_text?.ar, r.mark_text?.en]} />
            <div className="ms-rh__stage">
              <span className="ms-rh__stagelabel"><span className="ms-sr">{t("record.stage")} </span><span className="ms-num">{current}</span>{stageLabel(current)}</span>
              <span className={`ms-status ms-status--${statusGroup}`} title={t(`record.statusGroup.${statusGroup}`)}><span className="ms-status__mark" aria-hidden="true" />{r.status_label ? pickText(r.status_label, locale) : t(`record.statusGroup.${statusGroup}`)}</span>
            </div>
          </div>
          <div className="ms-rh__due"><span className="ms-cap">{t("record.nextDate")}</span>{nextChip}</div>
        </div>

        <ol className="ms-stagebar" aria-label={`${t("record.stage")} ${current} / 9: ${stageLabel(current)}`}>
          {STAGES.map((s, i) => {
            const n = i + 1; const ev = n in EVENT_STAGES;
            let cls = "ms-stage";
            if (n === current) cls += ` is-current${r.terminal ? " is-terminal" : ""}`;
            else if (ev) cls += ` is-event${eventsOn.has(n) ? " is-on" : ""}`;
            else if (skipped.has(n)) cls += " is-skipped";
            else if (n < current) cls += " is-done";
            return (
              <li key={s} className={cls} aria-current={n === current ? "step" : undefined} title={`${n} · ${t(`stages.${s}`)}`}>
                <span className="ms-stage__bar" /><span className="ms-stage__meta"><span className="ms-stage__n">{n}</span><span className="ms-stage__label">{t(`stages.${s}`)}</span></span>
              </li>
            );
          })}
        </ol>
        <div className="ms-stagebar__legend ms-cap">{t("record.eventNote")}</div>

        <div className="ms-rh__bottom">
          <div className="ms-flags">
            <span className="ms-rh__flagslabel">{t("record.flagsLabel")}</span>
            {[6, 8, 9].map((n) => <span key={n} className={`ms-flag${eventsOn.has(n) ? " is-on" : ""}`}><span className="ms-flag__n">{n}</span>{t(`record.flagNames.${n}`)} <span className="ms-flag__state">{eventsOn.has(n) ? "" : `· ${t("record.none")}`}</span></span>)}
          </div>
          <div className="ms-flags">
            {poaRelevant && r.poa_state !== "present" ? <span className="flag flag-red">{t(`record.poa.${r.poa_state}`)}</span> : null}
            {openWarnings.length ? <Link href={`${href("overview")}#checks`} className="flag flag-amber">{t("record.flags.warningsN", { n: openWarnings.length })}</Link> : null}
            {r.awaiting_deadline_entry ? <Link href={`${href("overview")}#next-dates`} className="flag flag-amber">{t("record.flags.deadline")}</Link> : null}
          </div>
        </div>
      </header>

      <nav className="tabs">{TABS.map((x) => <Link key={x} href={href(x)} className={x === tab ? "active" : ""}>{t(`record.tabs.${x}`)}{x === "documents" && r.documents.length ? <span className="ms-nav__n"> {r.documents.length}</span> : null}</Link>)}</nav>

      {tab === "overview" ? (
        <div className="ms-grid2">
          <div className="ms-stack">
            <Panel title={t("record.keyFacts")}>
              <dl className="ms-kv">
                <dt>{t("portfolio.cols.managedBy")}</dt><dd>{managedBy}</dd>
                <dt>{t("record.agentOfRecord")}</dt><dd>{r.agent_of_record ? pickText(r.agent_of_record, locale) : t("record.noAgentOfRecord")}</dd>
                <dt>{t("record.fee.state")}</dt><dd><span className={`ms-price__state ms-price__state--${r.paid_state === "paid" ? "paid" : r.paid_state === "read_only_unpaid" ? "due" : r.paid_state === "free_loaded" ? "loaded" : "free"}`}>{t(`record.paid.${r.paid_state}`)}</span></dd>
                <dt>{t("record.verifiedWithRegistry")}</dt><dd><span className="ms-cap">{t("record.notYetChecked")}</span></dd>
                <dt>{t("record.madrid.title")}</dt><dd><span className="ms-cap">{r.is_madrid ? JSON.stringify(r.madrid) : t("record.madrid.none")}</span></dd>
              </dl>
            </Panel>
            <Panel title={t("record.nextDates")} sub={t("record.nextDatesSub", { tz })}>
              <div id="next-dates" />
              {openTimers.length === 0 ? <p className="ms-sub">{t("dashboard.none")}</p> : (
                <div>
                  {openTimers.map((x) => (
                    <div key={x.id} className="ag-line">
                      {x.awaiting_user_entry ? (
                        <>
                          <Due t={t} what={timerLabel(t, x.timer_type)} date={null} awaiting />
                          {r.can_edit ? (
                            <form method="post" action={`/api/records/${id}/timers`} className="inline">
                              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="timer_id" value={x.id} />
                              <span className="ms-cap">{t("record.enterDeadline")}</span> <input type="date" name="due_date" required dir="ltr" className="ms-input" style={{ width: "auto" }} /> <button className="ms-btn ms-btn--sm" type="submit">{t("common.save")}</button>
                            </form>
                          ) : null}
                        </>
                      ) : <Due t={t} what={timerLabel(t, x.timer_type)} date={x.due_date} dateLabel={fmt(x.due_date!)} />}
                    </div>
                  ))}
                </div>
              )}
            </Panel>
          </div>
          <div className="ms-stack">
            {poaRelevant && r.poa_state !== "present" ? <div className="ms-note ms-note--danger"><div><div className="ms-note__t">{t(`record.poa.${r.poa_state}`)}</div><div>{t("record.poaBody")}</div></div></div> : null}
            {openWarnings.length ? (
              <Panel title={t("record.flags.warnings")} sub={t("record.checksSub")}>
                <div id="checks" />
                {openWarnings.map((w) => (
                  <div key={`${w.code}:${w.field}`} className="ag-line" style={{ alignItems: "flex-start" }}>
                    <span><b>{t(`intake.fields.${w.field}`)}</b><div className="ms-cap">{t(`checks.${w.code}`, w.params ?? {})}</div>
                      <div className="ms-row" style={{ marginTop: 6 }}>
                        <Btn href={href("certificate")} quiet sm>{t("record.fixValue")}</Btn>
                        {r.can_edit ? (
                          <form method="post" action={`/api/records/${id}/checks`} className="inline">
                            <input type="hidden" name="locale" value={locale} /><input type="hidden" name="code" value={w.code} /><input type="hidden" name="field" value={w.field} />
                            <input name="note" placeholder={t("intake.review.confirmPlaceholder")} className="ms-input" style={{ width: 220 }} />
                            <button type="submit" className="ms-btn ms-btn--sm ms-btn--quiet">{t("record.confirmCheck")}</button>
                          </form>
                        ) : null}
                      </div>
                    </span>
                  </div>
                ))}
              </Panel>
            ) : null}
            <Panel title={t("record.recentActivity")} actions={<Link href={href("timeline")} className="ms-link">{t("record.fullTimeline")}</Link>}>
              <Timeline items={tl.slice(0, 3)} />
            </Panel>
          </div>
        </div>
      ) : null}

      {tab === "mark" ? (
        <>
          <div className="ms-grid2">
            <Panel title={t("record.mark")}>
              <div className="ms-row" style={{ gap: 20, alignItems: "flex-start" }}>
                {r.mark_image_doc_id ? <a href={`/api/documents/${r.mark_image_doc_id}`} className="mark-image" style={{ width: 200 }}><img src={`/api/documents/${r.mark_image_doc_id}?inline=1`} alt={title} style={{ maxWidth: "100%", maxHeight: 160 }} /></a> : null}
                <div className="ms-stack" style={{ gap: 6 }}>
                  <MarkName as="div" runs={[r.mark_text?.ar, r.mark_text?.en]} />
                  <dl className="ms-kv">
                    <dt>{t("intake.markType")}</dt><dd>{t(`intake.markTypes.${r.mark_type}`)}</dd>
                    {r.mark_text?.en ? <><dt>{t("record.transliteration")}</dt><dd><bdi dir="ltr">{r.mark_text.en}</bdi></dd></> : null}
                  </dl>
                </div>
              </div>
            </Panel>
            <Panel title={t("record.classesTitle")}>
              {r.classes.map((c) => (
                <div key={c.number} className="ag-line" style={{ alignItems: "flex-start" }}>
                  <div><b><span className="num">{c.number}</span> · {pickText(c.heading, locale)}</b>{c.terms?.length ? <div className="ms-cap">{c.terms.map((x) => pickText(x, locale)).join("; ")}</div> : null}</div>
                </div>
              ))}
            </Panel>
          </div>
          <Panel title={t("record.markImage")} sub={t("record.imageWhy")}>
            {r.mark_image_doc_id ? (() => {
              const doc = r.documents.find((x) => x.id === r.mark_image_doc_id);
              return (
                <div className="mark-image-row">
                  <figure className="mark-image"><a href={`/api/documents/${r.mark_image_doc_id}`}><img src={`/api/documents/${r.mark_image_doc_id}?inline=1`} alt={title} /></a></figure>
                  <div className="small muted">
                    {doc ? <>{doc.file_name} · {fmt(doc.created_at)} · <a href={`/api/documents/${r.mark_image_doc_id}`} className="ms-link">{t("record.downloadOriginal")}</a><br /></> : null}
                    {t("record.imageHow")}
                  </div>
                </div>
              );
            })() : <p className="ms-sub">{t("record.noImage")}</p>}
            {r.can_edit ? (
              <form method="post" action={`/api/records/${id}/image`} encType="multipart/form-data" className="form upload-form">
                <input type="hidden" name="locale" value={locale} />
                <div className="grid-2">
                  <Field label={r.mark_image_doc_id ? t("record.replaceImage") : t("record.uploadImage")} name="file" required={false} hint={t("record.imageHint")}><input id="file" name="file" type="file" accept=".png,.jpg,.jpeg,.webp" required /></Field>
                </div>
                <div className="actions"><span /><button className="ms-btn ms-btn--quiet" type="submit">{t("intake.documents.upload")}</button></div>
              </form>
            ) : null}
          </Panel>
        </>
      ) : null}

      {tab === "certificate" ? (
        <Panel title={t("record.tabs.certificate")} sub={t("record.certificateNote")}>
          <form method="post" action={`/api/records/${id}/certificate`} className="form">
            <input type="hidden" name="locale" value={locale} />
            <div className="grid-2">
              <Field label={t("intake.applicationNo")} name="application_no" required={false}><input id="application_no" name="application_no" dir="ltr" defaultValue={r.application_no ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.filingDate")} name="filing_date" required={false}><input id="filing_date" name="filing_date" type="date" dir="ltr" defaultValue={r.filing_date ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.registrationNo")} name="registration_no" required={false}><input id="registration_no" name="registration_no" dir="ltr" defaultValue={r.registration_no ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.registrationDate")} name="registration_date" required={false}><input id="registration_date" name="registration_date" type="date" dir="ltr" defaultValue={r.registration_date ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.expiryDate")} name="expiry_date" required={false}><input id="expiry_date" name="expiry_date" type="date" dir="ltr" defaultValue={r.expiry_date ?? ""} disabled={!r.can_edit} /></Field>
            </div>
            {r.can_edit ? <div className="actions"><span /><button className="ms-btn" type="submit">{t("common.save")}</button></div> : <p className="ms-sub">{t("record.readOnly")}</p>}
          </form>
        </Panel>
      ) : null}

      {tab === "documents" ? (
        <Panel title={t("record.tabs.documents")}>
          {poaRelevant && r.poa_state !== "present" ? <div className="ms-note ms-note--danger"><div className="ms-note__t">{t(`record.poa.${r.poa_state}`)}</div></div> : null}
          {r.documents.length === 0 ? <Empty title={t("record.noDocuments")} body={t("record.noDocumentsBody")} /> : (
            <Table head={[t("intake.documents.type"), t("record.file"), t("record.vaultName"), t("record.validUntil"), t("record.added")]}>
              {r.documents.map((dd) => (
                <tr key={dd.id}><td><span className="ms-tag ms-tag--solid num">{dd.doc_type}</span> {t(`docTypes.${dd.doc_type}`)}</td>
                  <td><a href={`/api/documents/${dd.id}`} className="ms-link">{dd.file_name}</a></td>
                  <td className="ms-cap num">{dd.object_key.split("/").pop()}</td>
                  <td>{dateOrDash(dd.valid_until)}</td><td>{fmt(dd.created_at)}</td></tr>
              ))}
            </Table>
          )}
          {r.can_edit ? (
            <form method="post" action={`/api/records/${id}/documents`} encType="multipart/form-data" className="form upload-form">
              <input type="hidden" name="locale" value={locale} />
              <div className="grid-2">
                <Field label={t("intake.documents.type")} name="doc_type"><select id="doc_type" name="doc_type" defaultValue="ORC">{DOC_TYPES.map((c) => <option key={c} value={c}>{c} — {t(`docTypes.${c}`)}</option>)}</select></Field>
                <Field label={t("intake.documents.file")} name="file"><input id="file" name="file" type="file" accept=".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff" required /></Field>
                <Field label={t("record.validUntil")} name="valid_until" required={false} hint={t("record.validUntilHint")}><input id="valid_until" name="valid_until" type="date" dir="ltr" /></Field>
              </div>
              <div className="actions"><span /><button className="ms-btn ms-btn--quiet" type="submit">{t("intake.documents.upload")}</button></div>
            </form>
          ) : null}
        </Panel>
      ) : null}

      {tab === "timeline" ? (
        <div className="ms-grid2">
          <Panel title={t("record.tabs.timeline")} sub={t("record.timelineSub")}>
            {tl.length ? <Timeline items={tl} /> : <p className="ms-sub">—</p>}
          </Panel>
          <Panel title={t("record.stageChange.title")}>
            <div id="stage-change" />
            {r.can_edit ? (
              <form method="post" action={`/api/records/${id}/events`} className="form">
                <input type="hidden" name="locale" value={locale} />
                <Field label={t("record.stageChange.event")} name="event_type"><select id="event_type" name="event_type" required>{EVENTS.map((e) => <option key={e} value={e}>{t(`events.${e}`)}</option>)}</select></Field>
                <div className="grid-2">
                  <Field label={t("record.stageChange.date")} name="event_date"><input id="event_date" name="event_date" type="date" required dir="ltr" /></Field>
                  <Field label={t("record.stageChange.number")} name="number" required={false}><input id="number" name="number" dir="ltr" /></Field>
                </div>
                <Field label={t("record.stageChange.registryStatus")} name="registry_status" required={false} hint={t("record.stageChange.registryStatusHint")}><input id="registry_status" name="registry_status" /></Field>
                {r.holding_agency ? <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.stageChange.agencyNotifiedTitle")}</div><div>{t("record.stageChange.agencyNotified", { name: managedBy })}</div></div></div> : <p className="ms-sub">{t("record.stageChange.note")}</p>}
                <div className="actions"><span /><button className="ms-btn" type="submit">{t("record.stageChange.save")}</button></div>
              </form>
            ) : <p className="ms-sub">{t("record.readOnly")}</p>}
          </Panel>
        </div>
      ) : null}

      {tab === "agencies" ? (
        <div className="ms-grid2">
          <Panel title={t("record.holdingAgency")}>
            {r.holding_agency ? (
              <dl className="ms-kv"><dt>{t("record.agency")}</dt><dd>{pickText(r.holding_agency, locale)}</dd><dt>{t("record.agentOfRecord")}</dt><dd>{r.agent_of_record ? pickText(r.agent_of_record, locale) : "—"}</dd><dt>{t("record.poaLabel")}</dt><dd>{t(`record.poa.${r.poa_state}`)}</dd></dl>
            ) : <div className="ms-note ms-note--info"><div className="ms-note__t">{t("record.noAgency")}</div></div>}
          </Panel>
          <Panel title={t("record.addAgency")}>
            <p className="ms-sub">{t("record.agenciesLater")}</p>
            <div className="ms-row"><Btn disabled quiet title={t("common.comingSoon")}>{t("record.addAgency")}</Btn></div>
          </Panel>
        </div>
      ) : null}

      {tab === "watch" ? (
        <div className="ms-grid2">
          <Panel title={t("record.watchClasses")}>
            {r.watch_active ? <div className="ms-row">{r.classes.map((c) => <span key={c.number} className="ms-tag ms-tag--solid"><span className="num">{c.number}</span> · {pickText(c.heading, locale)}</span>)}</div>
              : <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.watchOff")}</div><div>{t("record.watchLater")}</div></div></div>}
          </Panel>
          <Panel title={t("record.watchAlerts")}><p className="ms-sub">{t("dashboard.noAlerts")}</p></Panel>
        </div>
      ) : null}

      {tab === "fee" ? (
        <Panel title={t("record.fee.title")}>
          <dl className="ms-kv">
            <dt>{t("record.fee.basis")}</dt><dd>{t(`record.fee.basisText.${r.paid_state}`)}</dd>
            {price ? <>
              <dt>{t("record.fee.yearsRemaining")}</dt><dd className="num">{price.years_remaining}</dd>
              <dt>{t("record.fee.price")}</dt><dd className="num">AED {price.amount}</dd>
              <dt>{t("record.fee.vat")}</dt><dd className="num">AED {price.vat}</dd>
            </> : null}
            <dt>{t("record.fee.state")}</dt><dd><span className={`ms-price__state ms-price__state--${r.paid_state === "paid" ? "paid" : r.paid_state === "read_only_unpaid" ? "due" : r.paid_state === "free_loaded" ? "loaded" : "free"}`}>{t(`record.paid.${r.paid_state}`)}</span></dd>
          </dl>
          <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.fee.pilot")}</div><div>{t("record.fee.pilotNote")} {t("record.fee.payLater")}</div></div></div>
        </Panel>
      ) : null}
    </>
  );
}
