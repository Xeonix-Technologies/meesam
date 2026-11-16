import Link from "next/link";
import type { ReactNode } from "react";
import type { translator } from "@meesam/i18n";
import { daysUntil } from "@/lib/timers";

/** Building blocks of the design system (Pilot Prototype `ds/bundle.css`), as server components. */

export function PageHead({ title, sub, eyebrow, actions }: { title: ReactNode; sub?: ReactNode; eyebrow?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="ms-ph">
      <div className="ms-ph__t">
        {eyebrow ? <span className="ms-cap">{eyebrow}</span> : null}
        <h1 className="ms-title">{title}</h1>
        {sub ? <p className="ms-sub">{sub}</p> : null}
      </div>
      {actions ? <div className="ms-row">{actions}</div> : null}
    </div>
  );
}

export function Panel({ title, sub, actions, children, className = "" }: { title?: ReactNode; sub?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`ms-panel ${className}`}>
      {title || actions ? (
        <div className="ms-panel__h">
          <div>{title ? <h2 className="ms-panel__title">{title}</h2> : null}{sub ? <p className="ms-sub">{sub}</p> : null}</div>
          {actions ? <div className="ms-row">{actions}</div> : null}
        </div>
      ) : null}
      {children}
    </section>
  );
}

export function Table({ head, children }: { head: ReactNode[]; children: ReactNode }) {
  return (
    <div className="ms-table-wrap"><table className="ms-table"><thead><tr>{head.map((h, i) => <th key={i}>{h}</th>)}</tr></thead><tbody>{children}</tbody></table></div>
  );
}

/** Bilingual mark name: each run is isolated and set in its own script. */
export function MarkName({ runs, size, as: Tag = "span" }: { runs: Array<string | null | undefined>; size?: "sm"; as?: "h1" | "span" | "div" }) {
  const list = runs.filter((r): r is string => !!r && r.trim().length > 0);
  return (
    <Tag className={size === "sm" ? "ms-markname ms-markname--sm" : "ms-markname"}>
      {list.map((r, i) => { const ar = /[\u0600-\u06FF]/.test(r); return <bdi key={i} className={ar ? "ms-ar" : "ms-lat"} lang={ar ? "ar" : "en"} dir={ar ? "rtl" : "ltr"}>{r}</bdi>; })}
    </Tag>
  );
}

/** A due date with its urgency tone; `awaiting` when the registry period is unverified and the user must enter the date. */
export function Due({ what, date, dateLabel, awaiting, t }: { what: ReactNode; date: string | null; dateLabel?: string; awaiting?: boolean; t: ReturnType<typeof translator> }) {
  if (awaiting || !date) return <span className="ms-due ms-due--none"><span className="ms-due__what">{what}</span><span className="ms-due__left">{t("record.flags.deadline")}</span></span>;
  const n = daysUntil(date);
  const tone = n < 0 ? "danger" : n <= 14 ? "danger" : n <= 60 ? "warn" : "ok";
  return (
    <span className={`ms-due ms-due--${tone}`}>
      <span className="ms-due__what">{what}</span>
      <span className="ms-due__date">{dateLabel ?? date}</span>
      <span className="ms-due__left">{t("record.daysRemaining", { n })}</span>
    </span>
  );
}

export function Empty({ title, body, actions }: { title: ReactNode; body?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="ms-empty">
      <span className="ms-empty__glyph" aria-hidden="true" />
      <h3 className="ms-empty__title">{title}</h3>
      {body ? <p className="ms-empty__body">{body}</p> : null}
      {actions ? <div className="ms-empty__acts">{actions}</div> : null}
    </div>
  );
}

export function Btn({ href, children, quiet, sm, disabled, title }: { href?: string; children: ReactNode; quiet?: boolean; sm?: boolean; disabled?: boolean; title?: string }) {
  const cls = `ms-btn${quiet ? " ms-btn--quiet" : ""}${sm ? " ms-btn--sm" : ""}`;
  if (!href || disabled) return <span className={cls} aria-disabled="true" title={title} style={disabled ? { opacity: 0.5, cursor: "not-allowed" } : undefined}>{children}</span>;
  return <Link href={href} className={cls}>{children}</Link>;
}
