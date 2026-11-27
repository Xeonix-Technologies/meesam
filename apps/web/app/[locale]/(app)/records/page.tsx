import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { listPortfolio, type RecordState } from "@/lib/records";
import { timerLabel } from "@/lib/timers";
import { Btn, Due, Empty, MarkName, PageHead, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

const STAGES = [
  "pre_filing", "filing_examination", "acceptance_publication_opposition", "appeals", "registration",
  "post_registration_recordals", "renewal_grace_expiry", "challenges", "enforcement",
] as const;
type Filters = { q?: string; registry?: string; stage?: string; status?: string; agency?: string; paid?: string; win?: string; fam?: string; page?: string };
/** Lines per page: a portfolio loaded in bulk runs to thousands of marks. */
const PER_PAGE = 100;

const group = (r: RecordState) => (r.terminal ? "terminal" : r.awaiting_deadline_entry || r.has_suggestions ? "user" : "progress");

/** Portfolio (Owner 3.3 / Agency 3.3; Pilot Prototype screen 3): every record the account owns, primary sort by stage. */
export default async function Portfolio({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<Filters> }) {
  const { locale } = await params;
  const f = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const t = translator(locale);
  const all = await listPortfolio(session);
  // An owner sees who manages each mark (Self or the agency); an agency sees whose mark it is (the client, or Self for its own).
  const isAgency = session.accountKind === "agency_office";
  const party = (r: RecordState) => (isAgency ? r.client : r.holding_agency);
  const partyCol = isAgency ? t("portfolio.cols.client") : t("portfolio.cols.managedBy");

  const agencies = new Map<string, string>();
  for (const r of all) { const p = party(r); if (p) agencies.set(JSON.stringify(p), pickText(p, locale)); }
  // search: the mark's name in either script, a number, or the client or agency; letter case, Arabic vowel marks and
  // the common spellings of alef, yaa and taa marbuta do not matter
  const fold = (v: string) => v.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f\u064B-\u065F\u0670\u0640]/g, "").replace(/[\u0622\u0623\u0625]/g, "\u0627").replace(/\u0649/g, "\u064A").replace(/\u0629/g, "\u0647").replace(/\s+/g, " ").trim();
  const q = fold((f.q ?? "").slice(0, 100));
  const found = (r: RecordState) => !q || [r.mark_text?.ar, r.mark_text?.en, r.registration_no, r.application_no, party(r) ? pickText(party(r), locale) : ""].some((v) => v && fold(v).includes(q));
  // a mark not yet activated shows its name only (Founder ruling 27 Nov 2026), so the filters on what is not shown pass it over
  const hidden = (r: RecordState) => !r.activated_at && !r.terminal;
  const match = (r: RecordState) =>
    found(r) &&
    (!f.registry || (!hidden(r) && r.registry_code === f.registry)) &&
    (!f.stage || (!hidden(r) && r.stage === f.stage)) &&
    (!f.status || (!hidden(r) && group(r) === f.status)) &&
    (!f.agency || (!hidden(r) && (f.agency === "self" ? !party(r) : JSON.stringify(party(r)) === f.agency))) &&
    (!f.paid || (f.paid === "not_active" ? !r.activated_at && !r.terminal : r.paid_state === f.paid)) &&
    (!f.win || (!hidden(r) && r.days_remaining != null && r.days_remaining <= Number(f.win)));
  const stageRank = (s: string) => (STAGES as readonly string[]).indexOf(s);
  const rows = all.filter(match).sort((a, b) => Number(hidden(a)) - Number(hidden(b)) || (hidden(a) ? 0 : stageRank(a.stage) - stageRank(b.stage)) || (a.days_remaining ?? 1e9) - (b.days_remaining ?? 1e9));
  const anyFilter = Boolean(q || f.registry || f.stage || f.status || f.agency || f.paid || f.win);

  // mark families with more than one record are shown as one expandable group (item 36)
  const fams = new Map<string, RecordState[]>();
  for (const r of rows) fams.set(r.mark_family_id, [...(fams.get(r.mark_family_id) ?? []), r]);
  const out: Array<{ fam: string; list: RecordState[] } | RecordState> = [];
  const seen = new Set<string>();
  for (const r of rows) {
    const list = fams.get(r.mark_family_id)!;
    if (list.length > 1) { if (!seen.has(r.mark_family_id)) { seen.add(r.mark_family_id); out.push({ fam: r.mark_family_id, list }); } }
    else out.push(r);
  }
  const pages = Math.max(1, Math.ceil(out.length / PER_PAGE));
  const pageNo = Math.min(pages, Math.max(1, Math.floor(Number(f.page)) || 1));
  const pageOut = out.slice((pageNo - 1) * PER_PAGE, pageNo * PER_PAGE);
  const openFam = f.fam;
  const qs = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries({ ...f, ...patch })) if (v) p.set(k, v);
    const s = p.toString();
    return `/${locale}/records${s ? `?${s}` : ""}`;
  };
  const registries = Array.from(new Set(all.map((r) => r.registry_code))).sort();
  // loaded in bulk and not active yet (migration 0104)
  const notActive = all.filter(hidden);
  const inBasket = notActive.filter((r) => r.activation_requested_at).length;

  const paidTone = (p: string) => (p === "paid" ? "paid" : p === "read_only_unpaid" ? "due" : p === "free_loaded" ? "loaded" : "free");
  const row = (r: RecordState, child = false) => {
    const g = group(r);
    const warnings = (r.warnings ?? []).filter((w) => !w.confirmed_at).length;
    if (hidden(r)) return (
      <tr key={r.record_id} className={child ? "ag-child" : undefined}>
        <td><Link href={`/${locale}/records/${r.record_id}`} className="ms-link"><MarkName size="sm" runs={[r.mark_text?.ar, r.mark_text?.en]} /></Link></td>
        <td colSpan={6} className="ms-cap">{t("record.activation.rowNote")}</td>
        <td><span className="ms-price__state ms-price__state--loaded">{t(r.activation_requested_at ? "record.activation.chipBasket" : "record.activation.chip")}</span></td>
        <td><span className="ms-cap">{t("common.off")}</span></td>
      </tr>
    );
    return (
      <tr key={r.record_id} className={child ? "ag-child" : undefined}>
        <td><Link href={`/${locale}/records/${r.record_id}`} className="ms-link"><MarkName size="sm" runs={[r.mark_text?.ar, r.mark_text?.en]} /></Link><div className="ms-cap num">{r.registration_no ?? r.application_no ?? ""}</div></td>
        <td>{r.registry_code}</td>
        <td><span className="num">{stageRank(r.stage) + 1}</span> · {t(`stages.${r.stage}`)}</td>
        <td><span className={`ms-status ms-status--${g}`} title={t(`record.statusGroup.${g}`)}><span className="ms-status__mark" aria-hidden="true" />{r.status_label ? pickText(r.status_label, locale) : t(`record.statusGroup.${g}`)}</span></td>
        <td>
          <span className="ms-flags">
            {r.holding_agency && r.poa_state !== "present" ? <span className="flag flag-red" title={t(`record.poa.${r.poa_state}`)}>POA</span> : null}
            {warnings ? <span className="flag flag-amber">{t("record.flags.warningsN", { n: warnings })}</span> : null}
            {r.awaiting_deadline_entry ? <span className="flag flag-amber">{t("record.flags.deadline")}</span> : null}
            {r.has_suggestions ? <span className="flag">{t("record.flags.suggestion")}</span> : null}
          </span>
        </td>
        <td>{r.next_due_date ? <Due t={t} what={timerLabel(t, r.next_timer_type)} date={r.next_due_date} dateLabel={formatDate(r.next_due_date, locale)} /> : r.awaiting_deadline_entry ? <Due t={t} what={t("record.flags.deadline")} date={null} awaiting /> : "—"}</td>
        <td>{party(r) ? pickText(party(r), locale) : t("portfolio.self")}</td>
        <td><span className={`ms-price__state ms-price__state--${paidTone(r.paid_state)}`}>{t(`record.paid.${r.paid_state}`)}</span></td>
        <td>{r.watch_active ? <span className="ms-fstate ms-fstate--ok">{t("common.on")}</span> : <span className="ms-cap">{t("common.off")}</span>}</td>
      </tr>
    );
  };

  const select = (name: keyof Filters, label: string, options: Array<[string, string]>) => (
    <label className="ms-field"><span className="ms-field__l">{label}</span>
      <select name={name} defaultValue={f[name] ?? ""} className="ms-input">{options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
    </label>
  );

  return (
    <>
      <PageHead title={t("portfolio.title")} sub={t("portfolio.sub")} actions={<><Btn href={`/${locale}/records/import`} quiet>{t("import.title")}</Btn><Btn href={`/${locale}/records/new`} quiet>{t("dashboard.actions.addExisting")}</Btn><Btn href={`/${locale}/records/request`}>{t("dashboard.actions.newFiling")}</Btn></>} />

      {all.length > 0 ? (
        <form method="get" className="ag-filters" action={`/${locale}/records`}>
          <label className="ms-field"><span className="ms-field__l">{t("portfolio.search")}</span>
            <input name="q" type="search" defaultValue={f.q ?? ""} maxLength={100} placeholder={t("portfolio.searchHint")} className="ms-input" />
          </label>
          {select("registry", t("portfolio.cols.registry"), [["", t("portfolio.all")], ...registries.map((c): [string, string] => [c, c])])}
          {select("stage", t("portfolio.cols.stage"), [["", t("portfolio.all")], ...STAGES.map((s, i): [string, string] => [s, `${i + 1} · ${t(`stages.${s}`)}`])])}
          {select("status", t("portfolio.cols.status"), [["", t("portfolio.all")], ["progress", t("record.statusGroup.progress")], ["user", t("record.statusGroup.user")], ["terminal", t("record.statusGroup.terminal")]])}
          {select("agency", partyCol, [["", t("portfolio.all")], ["self", t("portfolio.self")], ...Array.from(agencies.entries()).map(([k, v]): [string, string] => [k, v])])}
          {select("paid", t("portfolio.cols.paid"), [["", t("portfolio.all")], ["paid", t("record.paid.paid")], ["free_new_pending", t("record.paid.free_new_pending")], ["filing_paid", t("record.paid.filing_paid")], ["free_loaded", t("record.paid.free_loaded")], ["read_only_unpaid", t("record.paid.read_only_unpaid")], ...(notActive.length ? [["not_active", t("record.activation.chip")] as [string, string]] : [])])}
          {select("win", t("portfolio.window"), [["", t("portfolio.any")], ["30", t("portfolio.withinDays", { n: 30 })], ["90", t("portfolio.withinDays", { n: 90 })], ["365", t("portfolio.withinDays", { n: 365 })]])}
          <div className="ms-field"><span className="ms-field__l">&nbsp;</span><button type="submit" className="ms-btn ms-btn--quiet">{t("portfolio.apply")}</button></div>
        </form>
      ) : null}
      {notActive.length ? (
        <div className="ms-note ms-note--info"><div>
          <div className="ms-note__t">{t("portfolio.notActiveTitle", { n: notActive.length })}</div>
          <div>{t("portfolio.notActiveBody", { basket: inBasket })}</div>
          <div className="ms-row"><Link href={`/${locale}/basket`} className="ms-btn ms-btn--sm">{t("basket.title")}</Link><Link href={qs({ paid: "not_active", page: undefined })} className="ms-link">{t("basket.seeWaiting")}</Link></div>
        </div></div>
      ) : null}
      {anyFilter ? <div className="ms-row"><span className="ms-cap">{t("portfolio.countOf", { n: rows.length, total: all.length })}</span><Link href={`/${locale}/records`} className="ms-link">{t("portfolio.clearFilters")}</Link></div> : null}

      {all.length === 0 ? (
        <Empty title={t("portfolio.emptyTitle")} body={t("portfolio.empty")} actions={<Btn href={`/${locale}/records/new`}>{t("dashboard.actions.addExisting")}</Btn>} />
      ) : rows.length === 0 ? (
        <Empty title={t("portfolio.noMatchTitle")} body={t("portfolio.noMatch")} actions={<Btn href={`/${locale}/records`} quiet>{t("portfolio.clearFilters")}</Btn>} />
      ) : (
        <Table head={[t("portfolio.cols.mark"), t("portfolio.cols.registry"), t("portfolio.cols.stage"), t("portfolio.cols.status"), t("portfolio.cols.flags"), t("portfolio.cols.nextDate"), partyCol, t("portfolio.cols.paid"), t("portfolio.cols.watch")]}>
          {pageOut.map((x) => {
            if (!("fam" in x)) return row(x);
            const first = x.list[0]!;
            const open = openFam === x.fam;
            return [
              <tr key={`fam-${x.fam}`} className="ag-fam"><td colSpan={9}>
                <Link href={qs({ fam: open ? undefined : x.fam })} className="ag-famtoggle" aria-expanded={open}>
                  <span className={`ag-caret${open ? " is-open" : ""}`} />
                  <MarkName size="sm" runs={[first.mark_text?.ar, first.mark_text?.en]} />
                  <span className="ms-cap">{t("portfolio.family", { n: x.list.length })} · {x.list.map((r) => `${r.registry_code} (${party(r) ? pickText(party(r), locale) : t("portfolio.self")})`).join(locale === "ar" ? "، " : ", ")}</span>
                </Link>
              </td></tr>,
              ...(open ? x.list.map((r) => row(r, true)) : []),
            ];
          })}
        </Table>
      )}
      {pages > 1 ? (
        <nav className="ms-row" style={{ justifyContent: "space-between" }} aria-label={t("portfolio.pageOf", { n: pageNo, total: pages })}>
          {pageNo > 1 ? <Link href={qs({ page: String(pageNo - 1), fam: undefined })} className="ms-link" rel="prev">{t("portfolio.prevPage")}</Link> : <span />}
          <span className="ms-cap num">{t("portfolio.pageOf", { n: pageNo, total: pages })}</span>
          {pageNo < pages ? <Link href={qs({ page: String(pageNo + 1), fam: undefined })} className="ms-link" rel="next">{t("portfolio.nextPage")}</Link> : <span />}
        </nav>
      ) : null}
    </>
  );
}
