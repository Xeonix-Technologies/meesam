import type { ReactNode } from "react";
import { formatDateTime, type Locale, type Translator } from "@meesam/i18n";
import type { OpsReadRun } from "@/lib/ops";

const TONE: Record<string, string> = { queued: "flag flag-amber", reading: "flag flag-amber", stalled: "flag flag-red", done: "flag flag-green", failed: "flag flag-red", stopped: "flag flag-red" };
const SHOWN = 40;   // numbers listed in full before "and n more"

/**
 * One reading of a whole issue (plan item A1; migration 0067): how far it is, what it stored, and how what it read
 * compares with the registry's own index. Every mark it stored waits for a person to verify it.
 */
export function RunCard({ run: r, locale, t, lead, link }: { run: OpsReadRun; locale: Locale; t: Translator; lead: boolean; link?: ReactNode }) {
  const o = r.outcome;
  const live = r.status === "queued" || r.status === "reading" || r.status === "stalled";
  const list = (xs: string[]) => `${xs.slice(0, SHOWN).join(", ")}${xs.length > SHOWN ? ` ${t("ops.reading.whole.more", { n: xs.length - SHOWN })}` : ""}`;
  const agrees = o && o.index_read && (o.index_rows ?? 0) > 0 && !(o.missing?.length || o.not_in_index?.length || o.class_differs?.length || o.pages_not_read?.length);
  return (
    <div className="ops-src">
      <div className="ops-src__head">
        <div><b><span className="num">{r.code}</span> · {r.issue_no}</b> {r.from_page ? <span className="flag">{t("ops.reading.whole.pagesRange", { from: r.from_page, to: r.to_page ?? r.from_page })}</span> : null} <span className="ms-cap">· {t(`ops.reading.models.${r.model}`)}</span>
          <div className="ms-cap">{formatDateTime(r.created_at, locale)}{r.requested_by_name ? ` · ${r.requested_by_name}` : ""}{r.file_name ? <> · <span dir="ltr">{r.file_name}</span></> : null}</div>
        </div>
        <div className="ops-src__state"><span className={TONE[r.status] ?? "flag"}>{t(`ops.reading.whole.status.${r.status}`)}</span>
          {live && lead ? <form method="post" action="/api/ops" className="inline"><input type="hidden" name="locale" value={locale} /><input type="hidden" name="id" value={r.id} /><button type="submit" name="action" value="read_stop" className="ms-btn ms-btn--sm ms-btn--quiet">{t("ops.reading.whole.stop")}</button></form> : null}
        </div>
      </div>
      {r.error ? <div className={r.status === "failed" ? "ms-note ms-note--danger" : "ms-note"}><div>{r.error}</div></div> : null}
      {r.status === "stalled" ? <div className="ms-note ms-note--danger"><div>{t("ops.reading.whole.stalledNote")}</div></div> : null}
      <dl className="ops-facts">
        <div><dt>{t("ops.reading.whole.progress")}</dt><dd className="num">{r.parts_total ? t("ops.reading.whole.parts", { done: r.parts_done, n: r.parts_total }) : "—"}{r.parts_failed ? ` · ${t("ops.reading.whole.partsFailed", { n: r.parts_failed })}` : ""}</dd></div>
        <div><dt>{t("ops.reading.whole.stored")}</dt><dd className="num">{r.marks}</dd></div>
        <div><dt>{t("ops.reading.whole.file")}</dt><dd className="num">{r.page_count ? t("ops.reading.whole.fileFacts", { pages: r.page_count, first: r.first_page ?? 0, entries: r.entries_found ?? 0 }) : "—"}</dd></div>
        <div><dt>{t("ops.reading.whole.sizeLabel")}</dt><dd className="ms-cap">{t("ops.reading.size", { in: Number(r.input_tokens).toLocaleString(locale), out: Number(r.output_tokens).toLocaleString(locale), s: r.seconds ?? 0 })}</dd></div>
      </dl>
      {o && !live ? (
        <div className={agrees ? "ms-note ms-note--ok" : "ms-note"}>
          <div className="ms-note__t">{r.from_page ? t("ops.reading.whole.check.partial") : !o.index_read ? t("ops.reading.whole.check.noIndex") : (o.index_rows ?? 0) === 0 ? t("ops.reading.whole.check.indexEmpty") : agrees ? t("ops.reading.whole.check.agrees", { n: o.index_rows ?? 0 }) : t("ops.reading.whole.check.differs", { index: o.index_rows ?? 0, marks: o.marks ?? 0 })}</div>
          {o.missing?.length ? <div><b>{t("ops.reading.whole.check.missing", { n: o.missing.length })}</b> <span className="num" dir="ltr">{list(o.missing.map((x) => x.no))}</span></div> : null}
          {o.not_in_index?.length ? <div><b>{t("ops.reading.whole.check.notInIndex", { n: o.not_in_index.length })}</b> <span className="num" dir="ltr">{list(o.not_in_index.map((x) => x.no))}</span></div> : null}
          {o.class_differs?.length ? <div><b>{t("ops.reading.whole.check.classDiffers", { n: o.class_differs.length })}</b> <span className="num" dir="ltr">{list(o.class_differs.map((x) => `${x.no} (${x.index} / ${x.read.join(", ")})`))}</span></div> : null}
          {o.pages_not_read?.length ? <div><b>{t("ops.reading.whole.check.pagesNotRead", { n: o.pages_not_read.length })}</b> <span className="num" dir="ltr">{list(o.pages_not_read.map((x) => (x.from === x.to ? String(x.from) : `${x.from}–${x.to}`)))}</span></div> : null}
          {o.without_number ? <div>{t("ops.reading.whole.check.withoutNumber", { n: o.without_number })}</div> : null}
          {typeof o.entry_pages === "number" && o.entry_pages !== (o.marks ?? 0) ? <div>{t("ops.reading.whole.check.entryPages", { pages: o.entry_pages, marks: o.marks ?? 0 })}</div> : null}
        </div>
      ) : null}
      {r.marks > 0 && link ? <div>{link}</div> : null}
    </div>
  );
}
