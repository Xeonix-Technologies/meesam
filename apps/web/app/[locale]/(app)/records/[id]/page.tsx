import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { formatDate, formatDateTime, isLocale, pickText, translator } from "@meesam/i18n";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";
import { holdingAgencies, listMessages, markThreadRead, unreadOnRecord } from "@/lib/messages";
import { OtherAccount } from "@/components/OtherAccount";
import { LocalTime } from "@/components/LocalTime";
import { cookies } from "next/headers";
import { canTakeBack, latestPass } from "@/lib/pass";
import { listInstructions, namedOffices } from "@/lib/instructions";
import { listDirectory } from "@/lib/appointments";
import { appUrl } from "@/lib/mail";
import { timerLabel } from "@/lib/timers";
import { getRecord } from "@/lib/records";
import { DOC_TYPES } from "@/lib/upload";
import { Field } from "@/components/Field";
import { Btn, Due, Empty, MarkName, Panel, Table } from "@/components/ms";
import { PrintButton } from "@/components/PrintButton";
import { COUNTRIES } from "@/components/countries";

export const dynamic = "force-dynamic";

/** The nine stages of item 42, in order; 6, 8 and 9 run beside a registered mark (event stages). */
const STAGES = [
  "pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration",
  "post_registration_recordals", "renewal_grace_expiry", "challenges", "enforcement",
] as const;
const EVENT_STAGES: Record<number, string> = { 6: "recordal", 8: "challenged", 9: "enforcement" };
const TABS = ["overview", "request", "mark", "certificate", "documents", "timeline", "messages", "agencies", "watch", "fee"] as const;
const TABLE_NAMES: Record<string, true> = { record: true, record_class: true, record_event: true, document: true, timer: true, record_image: true };
const EVENTS = ["accepted", "office_action", "response_filed", "published", "opposed", "appealed", "registered", "declaration_of_use", "recordal", "renewed", "challenged", "enforcement", "refused", "withdrawn", "cancelled", "expired"];

/** Trademark record (Owner 3.4 / Agency 3.4; Pilot Prototype screen 4), laid out per item 37 as amended by item 42. */
export default async function RecordPage({ params, searchParams }: { params: Promise<{ locale: string; id: string }>; searchParams: Promise<{ tab?: string; error?: string; saved?: string; created?: string; for?: string }> }) {
  const { locale, id } = await params;
  const { tab: tabRaw, error, saved, created, for: forAccount } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  // a link from an e-mail names the account it was sent to; if another account is signed in here, say so
  if (forAccount && forAccount !== session.accountId) return <OtherAccount locale={locale} name={pickText(session.accountName, locale) || session.userName} email={session.email} />;
  const r = await getRecord(session, id);
  if (!r) notFound();
  const t = translator(locale);
  const tab = (TABS as readonly string[]).includes(tabRaw ?? "") ? (tabRaw as (typeof TABS)[number]) : "overview";
  // the thread with the other side (owner ↔ holding agency); opening the tab marks it read
  const messages = await listMessages(session, id);
  const unread = tab === "messages" ? 0 : await unreadOnRecord(session, id);
  if (tab === "messages" && messages.some((m) => !m.mine)) await markThreadRead(session, id);
  // the agencies on the thread: those holding the record under an appointment, and an office the owner instructed itself
  const parties = await holdingAgencies(session, id);
  const canWrite = session.role !== "viewer" && parties.length > 0;
  const agencies = session.accountKind !== "agency_office" ? parties : [];
  const manyAgencies = agencies.length > 1;
  // owner pass: an agency holding the record itself (entered for a client who is not yet its owner here) may issue one
  const agencyHolds = session.accountKind === "agency_office" && !r.client;
  const canIssuePass = agencyHolds && (session.role === "agency_admin" || session.role === "agent");
  const pass = agencyHolds && tab === "agencies" ? await latestPass(session, id) : null;
  const passCode = agencyHolds && tab === "agencies" ? (await cookies()).get(`ms_pass_${id}`)?.value ?? null : null;
  // a record handed over by a pass can be taken back by the agency that issued it, while it still manages the record
  const takeBackOk = session.accountKind === "agency_office" && Boolean(r.client) && tab === "agencies" && (session.role === "agency_admin" || session.role === "agent") ? await canTakeBack(session, id) : false;
  const passLive = pass && !pass.redeemed_at && new Date(String(pass.expires_at)).getTime() > Date.now();
  // cross-border instructions on this record: the office holding it instructs another office; the instructed office sees who instructed it
  const isAgency = session.accountKind === "agency_office";
  const instructions = tab === "agencies" ? await listInstructions(session, id) : [];
  // Founder ruling 19 Nov 2026: the owner of the trademark can send an instruction too
  const canInstruct = r.holds && (isAgency ? session.role === "agency_admin" || session.role === "agent" : session.role !== "viewer");
  const instrAdmin = session.role === (isAgency ? "agency_admin" : "company_admin");
  const canName = isAgency && (session.role === "agency_admin" || session.role === "agent");
  // for the owner: offices its agency chose to name on this trademark (item 26: hidden unless named)
  const named = !isAgency && tab === "agencies" ? await namedOffices(session, id) : [];
  const docsFor = (type: string) => r.documents.filter((d) => d.id !== r.mark_image_doc_id).sort((a, b) => Number(b.doc_type === type) - Number(a.doc_type === type));
  const firstOf = (type: string) => r.documents.find((d) => d.doc_type === type)?.id ?? "";
  const offices = canInstruct && tab === "agencies" ? await listDirectory(session) : [];
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
    ...r.events.map((e) => ({ key: `e${e.id}`, date: e.event_date, sort: e.created_at, event: t(`events.${e.event_type}`) + (e.registry_status ? ` — ${e.registry_status}` : ""), by: e.created_by_account ? pickText(e.created_by_account, locale) : e.created_through ? t("record.handledThrough", { agency: pickText(e.created_through, locale) }) : "Meesam", stage: true, pending: e.source === "suggested" && !e.confirmed_at })),
    ...r.edits.map((e) => ({ key: `x${e.id}`, date: e.created_at.slice(0, 10), sort: e.created_at, event: t("record.editOf", { table: TABLE_NAMES[e.table_name] ? t(`record.tables.${e.table_name}`) : e.table_name }), by: e.account ? pickText(e.account, locale) : e.through ? t("record.handledThrough", { agency: pickText(e.through, locale) }) : "—", stage: false, pending: false })),
    ...messages.map((m) => ({ key: `m${m.id}`, date: String(m.created_at).slice(0, 10), sort: String(m.created_at), event: `${t("record.messages.entry")}: ${m.body.length > 140 ? `${m.body.slice(0, 140)}…` : m.body}`, by: `${m.author_name} · ${pickText(m.author_account, locale)}`, stage: false, pending: false })),
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

  /** Open advisory checks, each with its two ways out: fix the value, or confirm it is correct (4.7 step 7). */
  const CERT_FIELDS = new Set(["application_no", "filing_date", "registration_no", "registration_date", "expiry_date"]);
  const warnFor = (field: string) => { const w = openWarnings.find((x) => x.field === field); return w ? t(`checks.${w.code}`, w.params ?? {}) : undefined; };
  const Checks = ({ onCertificate }: { onCertificate: boolean }) => (
    <div className="ms-note ms-note--warn checks-note" id="checks">
      <div style={{ flex: 1 }}>
        <div className="ms-note__t">{t("record.flags.warningsN", { n: openWarnings.length })}</div>
        <div className="ms-cap">{t("record.checksSub")}</div>
        {openWarnings.map((w) => (
          <div key={`${w.code}:${w.field}`} className="ag-line" style={{ alignItems: "flex-start" }}>
            <span><b>{t(`intake.fields.${w.field}`)}</b> — {t(`checks.${w.code}`, w.params ?? {})}
              {!CERT_FIELDS.has(w.field) || !onCertificate ? <> · <Link className="ms-link" href={`${href(CERT_FIELDS.has(w.field) ? "certificate" : w.field === "classes" ? "mark" : "timeline")}#checks`}>{t("record.fixValue")}</Link></> : <> · <span className="ms-cap">{t("record.highlightedBelow")}</span></>}
            </span>
            {r.can_edit ? (
              <form method="post" action={`/api/records/${id}/checks`} className="inline">
                <input type="hidden" name="locale" value={locale} /><input type="hidden" name="code" value={w.code} /><input type="hidden" name="field" value={w.field} />
                <input name="note" placeholder={t("intake.review.confirmPlaceholder")} className="ms-input" style={{ width: 200 }} />
                <button type="submit" className="ms-btn ms-btn--sm ms-btn--quiet">{t("record.confirmCheck")}</button>
              </form>
            ) : null}
          </div>
        ))}
      </div>
    </div>
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
      {saved === "passRedeemed" ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("pass.done", { agency: managedBy })}</div></div> : saved && !saved.startsWith("pass") && !saved.startsWith("instr") && saved !== "message" ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("common.saved")}</div></div> : null}
      {error && !error.startsWith("instr") ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`record.errors.${error}`)}</div></div> : null}
      {r.paid_state === "read_only_unpaid" ? <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.banners.unpaidTitle")}</div><div>{t("record.banners.unpaidBody")}</div></div></div> : null}
      {r.terminal ? <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("record.banners.closedTitle")}{r.status_label ? ` · ${pickText(r.status_label, locale)}` : ""}</div><div>{t("record.banners.closedBody")}</div></div></div> : null}

      {r.stage === "pre_filing" && r.filing_request && !r.terminal ? (
        <div className="ms-note ms-note--info no-print">
          <div><div className="ms-note__t">{t("record.request.bannerTitle")}</div><div>{t("record.request.bannerBody")}</div></div>
          <span className="ms-row"><Btn href={href("request")} quiet sm>{t("record.tabs.request")}</Btn>{r.can_edit ? <Btn href={`${href("timeline")}#stage-change`} sm>{t("record.request.recordFiled")}</Btn> : null}</span>
        </div>
      ) : null}

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
            {openWarnings.length ? <Link href={`${href("certificate")}#checks`} className="flag flag-amber">{t("record.flags.warningsN", { n: openWarnings.length })}</Link> : null}
            {r.awaiting_deadline_entry ? <Link href={`${href("overview")}#next-dates`} className="flag flag-amber">{t("record.flags.deadline")}</Link> : null}
          </div>
        </div>
      </header>

      <nav className="tabs no-print">{TABS.filter((x) => x !== "request" || r.filing_request).map((x) => <Link key={x} href={href(x)} className={x === tab ? "active" : ""}>{x === "agencies" && session.accountKind === "agency_office" ? t("record.tabs.agenciesForAgency") : t(`record.tabs.${x}`)}{x === "documents" && r.documents.length ? <span className="ms-nav__n"> {r.documents.length}</span> : null}{x === "messages" && unread ? <span className="nav-badge"> {unread}</span> : x === "messages" && messages.length ? <span className="ms-nav__n"> {messages.length}</span> : null}</Link>)}</nav>

      {tab === "overview" && agencyHolds ? (
        <div className="ms-note ms-note--info"><div>
          <div className="ms-note__t">{t("record.pass.overviewTitle")}</div>
          <div>{t("record.pass.overviewBody")} <Link href={href("agencies")} className="ms-link">{t("record.pass.overviewLink")}</Link></div>
        </div></div>
      ) : null}
      {tab === "overview" ? (
        <div className="ms-grid2">
          <div className="ms-stack">
            <Panel title={t("record.keyFacts")}>
              <dl className="ms-kv">
                <dt>{t("portfolio.cols.managedBy")}</dt><dd>{managedBy}</dd>
                <dt>{t("record.agentOfRecord")}</dt><dd>{r.agent_of_record ? pickText(r.agent_of_record, locale) : t("record.noAgentOfRecord")}</dd>
                <dt>{t("record.fee.state")}</dt><dd><span className={`ms-price__state ms-price__state--${r.paid_state === "paid" ? "paid" : r.paid_state === "read_only_unpaid" ? "due" : r.paid_state === "free_loaded" ? "loaded" : "free"}`}>{t(`record.paid.${r.paid_state}`)}</span></dd>
                <dt>{t("record.verifiedWithRegistry")}</dt>
                <dd>
                  {r.registry_checked_at
                    ? <span>{t("record.registryCheckedBy", { name: r.registry_checked_by?.user ?? "", account: pickText(r.registry_checked_by?.account ?? null, locale), date: fmt(String(r.registry_checked_at).slice(0, 10)) })}</span>
                    : <span className="ms-cap">{t("record.notYetChecked")}</span>}
                  {r.can_edit && session.role !== "viewer" ? (
                    <form method="post" action={`/api/records/${id}/registry-check`} className="inline">
                      <input type="hidden" name="locale" value={locale} /><input type="hidden" name="checked" value={r.registry_checked_at ? "0" : "1"} />
                      <button type="submit" className="ms-btn ms-btn--sm ms-btn--quiet" title={t("record.registryCheckHint")}>{r.registry_checked_at ? t("record.registryCheckWithdraw") : t("record.registryCheckDo")}</button>
                    </form>
                  ) : null}
                  <div className="ms-cap">{t("record.registryCheckHint")}</div>
                </dd>
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
            {openWarnings.length ? <Checks onCertificate={false} /> : null}
            <Panel title={t("record.recentActivity")} actions={<Link href={href("timeline")} className="ms-link">{t("record.fullTimeline")}</Link>}>
              <Timeline items={tl.slice(0, 3)} />
            </Panel>
          </div>
        </div>
      ) : null}

      {tab === "request" && r.filing_request ? (() => {
        const q = r.filing_request as { applicant?: Record<string, string | null>; route?: Record<string, string | null>; mark?: Record<string, string | null>; priority?: Record<string, string | null> | null; declarations?: { accuracy?: boolean }; accepted_at?: string };
        const country = (code?: string | null) => { const c = COUNTRIES.find((x) => x.code === code); return c ? (locale === "ar" ? c.ar : c.en) : code ?? "—"; };
        const v = (x?: string | null) => x || "—";
        return (
          <Panel title={t("record.request.title")} sub={t("record.request.sub")} actions={<PrintButton label={t("record.request.print")} />} className="print-area">
            <h3 className="ms-cap">{t("filing.steps.1")}</h3>
            <dl className="ms-kv">
              <dt>{t("filing.applicantNameAr")}</dt><dd lang="ar" dir="rtl">{v(q.applicant?.name_ar)}</dd>
              <dt>{t("filing.applicantNameEn")}</dt><dd>{v(q.applicant?.name_en)}</dd>
              <dt>{t("filing.legalForm")}</dt><dd>{v(q.applicant?.legal_form)}</dd>
              <dt>{t("filing.nationality")}</dt><dd>{country(q.applicant?.nationality)}</dd>
              <dt>{t("filing.address")}</dt><dd>{v(q.applicant?.address)}</dd>
              <dt>{t("filing.email")}</dt><dd className="num">{v(q.applicant?.email)}</dd>
              <dt>{t("filing.phone")}</dt><dd className="num">{v(q.applicant?.phone)}</dd>
            </dl>
            <h3 className="ms-cap">{t("filing.steps.2")}</h3>
            <dl className="ms-kv">
              <dt>{t("intake.registry")}</dt><dd>{pickText(r.registry_name, locale) || r.registry_code}</dd>
              <dt>{t("filing.whoFiles")}</dt><dd>{q.route?.who === "agency" ? `${t("filing.routeAgency")}${r.agent_of_record ? ` — ${pickText(r.agent_of_record, locale)}` : q.route?.agency_named ? ` — ${q.route.agency_named}` : ""}` : t("filing.routeSelf")}</dd>
            </dl>
            <h3 className="ms-cap">{t("filing.steps.3")}</h3>
            <dl className="ms-kv">
              <dt>{t("intake.markType")}</dt><dd>{t(`intake.markTypes.${r.mark_type}`)}</dd>
              <dt>{t("intake.markTextAr")}</dt><dd lang="ar" dir="rtl">{v(r.mark_text?.ar)}</dd>
              <dt>{t("intake.markTextEn")}</dt><dd>{v(r.mark_text?.en)}</dd>
              <dt>{t("filing.transliteration")}</dt><dd>{v(q.mark?.transliteration)}</dd>
              <dt>{t("filing.translation")}</dt><dd>{v(q.mark?.translation)}</dd>
              <dt>{t("filing.colourClaim")}</dt><dd>{v(q.mark?.colour_claim)}</dd>
              <dt>{t("filing.description")}</dt><dd>{v(q.mark?.description)}</dd>
            </dl>
            {r.mark_image_doc_id ? <figure className="mark-image" style={{ display: "inline-block" }}><img src={`/api/documents/${r.mark_image_doc_id}?inline=1`} alt={title} style={{ maxHeight: 200 }} /></figure> : null}
            <h3 className="ms-cap">{t("filing.steps.4")}</h3>
            {r.classes.map((c) => (
              <div key={c.id} className="ag-line" style={{ alignItems: "flex-start" }}>
                <div><b><span className="num">{c.number}</span> · {pickText(c.heading, locale)}</b><div className="ms-cap">{c.terms?.length ? c.terms.map((x) => pickText(x, locale)).join("; ") : t("filing.headingUsed")}</div></div>
              </div>
            ))}
            <h3 className="ms-cap">{t("filing.steps.5")}</h3>
            <p>{q.priority ? `${country(q.priority.country)} · ${v(q.priority.number)} · ${q.priority.date ? fmt(q.priority.date) : "—"}` : t("filing.priorityNo")}</p>
            <h3 className="ms-cap">{t("filing.steps.6")}</h3>
            <p>{r.documents.filter((x) => x.id !== r.mark_image_doc_id).map((x) => `${x.doc_type} — ${x.file_name}`).join("; ") || t("dashboard.none")}</p>
            <p className="ms-cap">{q.accepted_at ? t("record.request.acceptedOn", { date: fmt(q.accepted_at.slice(0, 10)) }) : ""} · {t("filing.notDone")}</p>
          </Panel>
        );
      })() : null}

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
            <Panel title={t("record.classesTitle")} sub={r.can_edit ? t("record.classesEditSub") : undefined}>
              {r.can_edit ? (
                <form method="post" action={`/api/records/${id}/classes`} className="form">
                  <input type="hidden" name="locale" value={locale} />
                  {r.classes.map((c) => {
                    const goods = c.terms?.map((x) => x.ar ?? x.en ?? "").filter(Boolean).join("; ") ?? "";
                    return (
                      <div key={c.id} className="class-edit">
                        <input type="hidden" name="class_id" value={c.id} />
                        <label className="field"><span className="field-label">{t("record.classNumber")}</span>
                          <input name={`number:${c.id}`} type="number" min={1} max={45} required defaultValue={c.number} dir="ltr" className="num" /></label>
                        <label className="field"><span className="field-label">{t("intake.goods")}</span>
                          <textarea name={`goods:${c.id}`} rows={3} defaultValue={goods} dir="auto" />
                          <span className="field-hint">{pickText(c.heading, locale)}</span></label>
                      </div>
                    );
                  })}
                  <div className="actions"><span className="muted small">{t("record.classesNoAdd")}</span><button className="ms-btn" type="submit">{t("common.save")}</button></div>
                </form>
              ) : r.classes.map((c) => (
                <div key={c.id} className="ag-line" style={{ alignItems: "flex-start" }}>
                  <div><b><span className="num">{c.number}</span> · {pickText(c.heading, locale)}</b>{c.terms?.length ? <div className="ms-cap">{c.terms.map((x) => pickText(x, locale)).join("; ")}</div> : null}</div>
                </div>
              ))}
            </Panel>
          </div>
          {r.can_edit ? (
            <Panel title={t("record.editMark")} sub={t("record.editMarkSub")}>
              <form method="post" action={`/api/records/${id}/mark`} className="form">
                <input type="hidden" name="locale" value={locale} />
                <fieldset className="field">
                  <legend className="field-label">{t("intake.markType")}</legend>
                  <div className="grid-3">
                    {(["word", "device", "combined"] as const).map((m) => (
                      <label key={m} className="choice-row"><input type="radio" name="mark_type" value={m} required defaultChecked={r.mark_type === m} /> <span>{t(`intake.markTypes.${m}`)}</span></label>
                    ))}
                  </div>
                </fieldset>
                <div className="grid-2">
                  <Field label={t("intake.markTextAr")} name="mark_text_ar" required={false}><input id="mark_text_ar" name="mark_text_ar" dir="rtl" lang="ar" defaultValue={r.mark_text?.ar ?? ""} /></Field>
                  <Field label={t("intake.markTextEn")} name="mark_text_en" required={false}><input id="mark_text_en" name="mark_text_en" dir="ltr" lang="en" defaultValue={r.mark_text?.en ?? ""} /></Field>
                </div>
                <div className="actions"><span className="muted small">{t("record.certificateNote")}</span><button className="ms-btn" type="submit">{t("common.save")}</button></div>
              </form>
            </Panel>
          ) : null}
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
          {openWarnings.length ? <Checks onCertificate /> : null}
          <form method="post" action={`/api/records/${id}/certificate`} className="form">
            <input type="hidden" name="locale" value={locale} />
            <div className="grid-2">
              <Field label={t("intake.applicationNo")} name="application_no" required={false} error={warnFor("application_no")}><input id="application_no" name="application_no" dir="ltr" defaultValue={r.application_no ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.filingDate")} name="filing_date" required={false} error={warnFor("filing_date")}><input id="filing_date" name="filing_date" type="date" dir="ltr" defaultValue={r.filing_date ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.registrationNo")} name="registration_no" required={false} error={warnFor("registration_no")}><input id="registration_no" name="registration_no" dir="ltr" defaultValue={r.registration_no ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.registrationDate")} name="registration_date" required={false} error={warnFor("registration_date")}><input id="registration_date" name="registration_date" type="date" dir="ltr" defaultValue={r.registration_date ?? ""} disabled={!r.can_edit} /></Field>
              <Field label={t("intake.expiryDate")} name="expiry_date" required={false} error={warnFor("expiry_date")}><input id="expiry_date" name="expiry_date" type="date" dir="ltr" defaultValue={r.expiry_date ?? ""} disabled={!r.can_edit} /></Field>
            </div>
            <label className="check"><input type="checkbox" name="priority_claimed" value="1" defaultChecked={r.priority_claimed} disabled={!r.can_edit} /> {t("record.priorityClaimed")}</label>
            <p className="ms-cap">{t("record.priorityClaimedHint")}</p>
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
                <Field label={t("record.stageChange.event")} name="event_type"><select id="event_type" name="event_type" required>{(r.stage === "pre_filing" ? ["filed", "withdrawn"] : EVENTS).map((e) => <option key={e} value={e}>{t(`events.${e}`)}</option>)}</select></Field>
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

      {tab === "messages" ? (
        <Panel title={t("record.tabs.messages")} sub={parties.length || messages.length ? t("record.messages.sub", { other: manyAgencies ? agencies.map((a) => pickText(a.name, locale)).join(locale === "ar" ? "، " : ", ") : messages[0] ? pickText(messages[0].other_account, locale) : r.client ? pickText(r.client, locale) : managedBy }) : undefined}>
          {error === "messageEmpty" || error === "messageNoAgency" || error === "messagePick" ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`record.messages.errors.${error}`)}</div></div> : null}
          {messages.length === 0 ? <p className="ms-sub">{parties.length ? t("record.messages.none") : t("record.messages.noAgency")}</p> : (
            <ol className="msg-list">
              {messages.map((m) => (
                <li key={m.id} className={`msg${m.mine ? " msg--mine" : ""}`}>
                  <div className="msg__meta"><b>{m.author_name}</b> · {pickText(m.author_account, locale)}{manyAgencies && m.mine ? <> → {pickText(m.other_account, locale)}</> : null} · <LocalTime iso={new Date(String(m.created_at)).toISOString()} locale={locale} fallback={formatDateTime(String(m.created_at), locale)} /></div>
                  <div className="msg__body">{m.body}</div>
                </li>
              ))}
            </ol>
          )}
          {canWrite ? (
            <form method="post" action={`/api/records/${id}/messages`} className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="mark" value={title} />
              {manyAgencies ? (
                <fieldset className="ms-field"><legend className="ms-field__l">{t("record.messages.sendTo")}</legend><input type="hidden" name="multi" value="1" />
                  <div className="record-picks">{agencies.map((a) => <label key={a.id} className="check"><input type="checkbox" name="agency" value={a.id} defaultChecked /> {pickText(a.name, locale)}</label>)}</div>
                </fieldset>
              ) : null}
              <label className="ms-field"><span className="ms-field__l">{t("record.messages.write")}</span><textarea name="body" rows={3} maxLength={4000} required className="ms-input" /></label>
              <div className="ms-row" style={{ justifyContent: "space-between" }}><span className="ms-cap">{t("record.messages.note")}</span><button type="submit" className="ms-btn">{t("record.messages.send")}</button></div>
            </form>
          ) : parties.length ? <p className="ms-cap">{t("record.messages.viewer")}</p> : null}
        </Panel>
      ) : null}

      {tab === "agencies" && named.length ? (
        <Panel title={t("instructions.namedTitle")}>
          {named.map((n, k) => <p key={k} className="ms-sub">{t("instructions.namedLine", { office: pickText(n.office, locale), country: n.country ?? "", agency: pickText(n.through, locale) })}</p>)}
        </Panel>
      ) : null}

      {tab === "agencies" && (canInstruct || instructions.length) ? (
        <Panel title={t("instructions.onRecord")} sub={r.holds ? t(isAgency ? "instructions.onRecordSub" : "instructions.onRecordSubOwner") : undefined}>
          {saved?.startsWith("instr") ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`instructions.saved.${saved}`)}</div></div> : null}
          {error?.startsWith("instr") ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`instructions.errors.${error}`)}</div></div> : null}
          {instructions.map((i) => (
            <div key={i.id} className="ag-line">
              <span><b>{pickText(i.other_name, locale)}</b> <span className="ms-cap">{t(`instructions.direction.${i.direction}`)} · {t(`instructions.status.${i.status === "active" && !i.in_force ? "notInForce" : i.status}`)} · {formatDate(i.accepted_at ?? i.created_at, locale)}{i.decline_note ? ` · “${i.decline_note}”` : ""}</span></span>
              <span className="ms-row">
              {i.legal_doc_name ? <a href={`/api/instructions/${i.id}/doc?which=legal`} className="ms-link">{t("instructions.legalDoc")}</a> : null}
              {i.poa_doc_name ? <a href={`/api/instructions/${i.id}/doc?which=poa`} className="ms-link">{t("instructions.poaDoc")}</a> : null}
              {i.direction === "sent" && !i.from_is_owner && (i.status === "active" || i.status === "requested") && canName ? (
                <form method="post" action="/api/instructions" className="inline">
                  <input type="hidden" name="locale" value={locale} /><input type="hidden" name="from" value="record" /><input type="hidden" name="record_id" value={id} /><input type="hidden" name="instruction_id" value={i.id} />
                  <button type="submit" name="action" value={i.named_to_owner ? "unname" : "name"} className="ms-btn ms-btn--sm ms-btn--quiet" title={t("instructions.nameHint")}>{t(i.named_to_owner ? "instructions.unname" : "instructions.name")}</button>
                </form>
              ) : null}
              {(i.status === "active" || (i.status === "requested" && i.direction === "sent")) && instrAdmin ? (
                <form method="post" action="/api/instructions" className="inline">
                  <input type="hidden" name="locale" value={locale} /><input type="hidden" name="from" value="record" /><input type="hidden" name="record_id" value={id} /><input type="hidden" name="instruction_id" value={i.id} />
                  <button type="submit" name="action" value="end" className="ms-btn ms-btn--sm ms-btn--quiet">{t(i.status === "requested" ? "instructions.withdraw" : "instructions.end")}</button>
                </form>
              ) : null}
              </span>
            </div>
          ))}
          {canInstruct ? (
            <form method="post" action="/api/instructions" className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="from" value="record" /><input type="hidden" name="record_id" value={id} /><input type="hidden" name="action" value="request" />
              <div className="grid-2">
                <label className="ms-field"><span className="ms-field__l">{t("instructions.pickOffice")}</span>
                  <select name="account_id" className="ms-input" defaultValue=""><option value="">{t("instructions.pickNone")}</option>{offices.map((o) => <option key={o.id} value={o.id}>{`${pickText(o.name, locale)} · ${o.country}${o.city ? ` · ${o.city}` : ""}`}</option>)}</select></label>
                <label className="ms-field"><span className="ms-field__l">{t("instructions.orEmail")}</span><input name="email" type="email" dir="ltr" maxLength={254} autoComplete="off" className="ms-input" /></label>
              </div>
              <div className="grid-2">
                <label className="ms-field"><span className="ms-field__l">{t("instructions.attachLegal")}</span>
                  <select name="legal_doc" className="ms-input" defaultValue={firstOf("LGR")}><option value="">{t("instructions.attachNone")}</option>{docsFor("LGR").map((d) => <option key={d.id} value={d.id}>{`${d.doc_type} · ${d.file_name}`}</option>)}</select></label>
                <label className="ms-field"><span className="ms-field__l">{t("instructions.attachPoa")}</span>
                  <select name="poa_doc" className="ms-input" defaultValue={firstOf("POA")}><option value="">{t("instructions.attachNone")}</option>{docsFor("POA").map((d) => <option key={d.id} value={d.id}>{`${d.doc_type} · ${d.file_name}`}</option>)}</select></label>
              </div>
              <p className="ms-cap">{t("instructions.attachNote")}</p>
              <label className="ms-field"><span className="ms-field__l">{t("links.message")}</span><input name="message" className="ms-input" maxLength={1000} /></label>
              <div className="ms-row" style={{ justifyContent: "space-between" }}><span className="ms-cap">{t("instructions.sendNote")}</span><button type="submit" className="ms-btn">{t("instructions.send")}</button></div>
            </form>
          ) : null}
          {instructions.length ? <p><Link href={`/${locale}/instructions`} className="ms-link">{t("instructions.all")}</Link></p> : null}
        </Panel>
      ) : null}

      {tab === "agencies" && (takeBackOk || error === "passTakeBack") ? (
        <Panel title={t("record.pass.takeBackTitle")} sub={t("record.pass.takeBackSub", { owner: r.client ? pickText(r.client, locale) : "" })}>
          {error === "passTakeBack" ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t("record.pass.errors.passTakeBack")}</div></div> : null}
          {takeBackOk ? (
            <form method="post" action={`/api/records/${id}/pass`} className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="takeback" /><input type="hidden" name="mark" value={title} />
              <label className="check"><input type="checkbox" name="confirm" value="1" required /> {t("record.pass.takeBackConfirm", { owner: r.client ? pickText(r.client, locale) : "" })}</label>
              <div className="ms-row" style={{ justifyContent: "flex-end" }}><button type="submit" className="ms-btn ms-btn--danger">{t("record.pass.takeBack")}</button></div>
            </form>
          ) : null}
        </Panel>
      ) : null}

      {tab === "agencies" && agencyHolds ? (
        <Panel title={t("record.pass.title")} sub={t("record.pass.sub")}>
          {saved === "passTakenBack" ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("record.pass.saved.passTakenBack")}</div></div> : null}
          {saved === "pass" || saved === "passSent" || saved === "passNoMail" ? <div className={`ms-note ms-note--${saved === "passNoMail" ? "warn" : "ok"}`} role="status"><div className="ms-note__t">{t(`record.pass.saved.${saved}`)}</div></div> : null}
          {error === "pass" || error === "passEmail" ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`record.pass.errors.${error}`)}</div></div> : null}
          {passCode && passLive ? (
            <div className="pass-code"><span className="ms-cap">{t("record.pass.codeOnce")}</span><b className="num" dir="ltr">{passCode}</b><span className="ms-cap num" dir="ltr">{`${appUrl()}/${locale}/pass`}</span></div>
          ) : null}
          {pass ? (
            <dl className="ms-kv">
              <dt>{t("record.pass.state")}</dt><dd>{pass.redeemed_at ? t("record.pass.redeemed", { date: fmt(String(pass.redeemed_at).slice(0, 10)) }) : passLive ? t("record.pass.live", { date: fmt(String(pass.expires_at).slice(0, 10)) }) : t("record.pass.expired")}</dd>
              {pass.sent_to ? <><dt>{t("record.pass.sentTo")}</dt><dd dir="ltr">{pass.sent_to}</dd></> : null}
            </dl>
          ) : <p className="ms-sub">{t("record.pass.none")}</p>}
          {canIssuePass ? (
            <form method="post" action={`/api/records/${id}/pass`} className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="mark" value={title} />
              <div className="grid-2">
                <label className="ms-field"><span className="ms-field__l">{t("record.pass.email")}</span><input name="email" type="email" dir="ltr" className="ms-input" maxLength={200} /></label>
                <label className="ms-field"><span className="ms-field__l">{t("record.pass.mailLanguage")}</span><select name="mail_locale" className="ms-input" defaultValue={locale}><option value="en">English</option><option value="ar">العربية</option></select></label>
              </div>
              <div className="ms-row" style={{ justifyContent: "space-between" }}><span className="ms-cap">{passLive ? t("record.pass.replaces") : t("record.pass.rules")}</span><button type="submit" className="ms-btn">{passLive ? t("record.pass.issueNew") : t("record.pass.issue")}</button></div>
            </form>
          ) : null}
        </Panel>
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
