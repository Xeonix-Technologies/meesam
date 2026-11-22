"use client";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

/**
 * What arrives a little after a mark is opened in the reviewer's queue: its translation and its gazette page(s).
 * Both are asked for when the page is opened; this asks the server again every few seconds until they are there
 * and puts them in place, without reloading the page, so nothing the reviewer has typed is lost.
 */
export interface Aux { t: Partial<Record<string, string>> | null; t_pending: boolean; has_page: boolean; page_pending: boolean }
const Ctx = createContext<Aux>({ t: null, t_pending: false, has_page: false, page_pending: false });
const wanting = (a: Aux) => (a.t === null && a.t_pending) || (!a.has_page && a.page_pending);

export function AuxProvider({ url, initial, children }: { url: string; initial: Aux; children: ReactNode }) {
  const [aux, setAux] = useState<Aux>(initial);
  useEffect(() => {
    let live = true; let n = 0; let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      if (!live) return;
      n += 1;
      let next: Aux | null = null;
      try { const r = await fetch(url, { cache: "no-store", credentials: "same-origin" }); if (r.ok) next = (await r.json()) as Aux; } catch { /* asked again below */ }
      if (!live) return;
      if (next) setAux(next);
      // about five minutes at most; a translation takes seconds, a page of a large bulletin up to a few minutes
      if ((!next || wanting(next)) && n < 75) timer = setTimeout(tick, 4000);
    };
    if (wanting(initial)) timer = setTimeout(tick, 2500);
    return () => { live = false; if (timer) clearTimeout(timer); };
  }, [url]); // eslint-disable-line react-hooks/exhaustive-deps
  return <Ctx.Provider value={aux}>{children}</Ctx.Provider>;
}

/** The translation of one field, in its own box under the registry's text. Nothing is drawn when there is none. */
export function TrUnder({ field, also, label, pendingText }: { field: string; also?: string; label: string; pendingText?: string }) {
  const a = useContext(Ctx);
  const text = [a.t?.[field], also ? a.t?.[also] : null].filter(Boolean).join(" · ");
  if (text) return <div className="tr-under" role="note"><span className="tr-under__l">{label}</span><span className="tr-under__t" dir="auto">{text}</span></div>;
  if (pendingText && a.t === null && a.t_pending) return <div className="tr-under tr-under--wait"><span className="tr-under__l">{label}</span><span>{pendingText}</span></div>;
  return null;
}

/** The notice under the fields: shown only when a translation is on the page. */
export function TrNote({ children }: { children: ReactNode }) {
  const a = useContext(Ctx);
  return a.t && Object.keys(a.t).some((k) => ["applicant_name", "applicant_address", "agent_name", "agent_city", "goods"].includes(k)) ? <p className="ms-cap vq__wide">{children}</p> : null;
}

/** The gazette page(s) of the mark; while they are being cut out of the issue, a line that says so. */
export function PageFrame({ src, title, waiting, none, children }: { src: string; title: string; waiting: string; none: string; children?: ReactNode }) {
  const a = useContext(Ctx);
  if (a.has_page) return <><iframe className="vq__frame" title={title} src={src} />{children}</>;
  return <div className="ms-note"><div className="ms-note__t">{a.page_pending ? waiting : none}</div></div>;
}
