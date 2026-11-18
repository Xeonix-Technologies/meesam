"use client";
import { useEffect, useRef, useState } from "react";

/**
 * Picks goods and services from the Nice list for one class (Section 6 group 4). What the user picks is added
 * to the class's text box, separated by semicolons, so the text stays the one thing saved and can still be
 * typed or edited freely (advisory, never blocking).
 */
export function TermPicker({ classNumber, lang, target, labels }: { classNumber: number; lang: string; target: string; labels: { search: string; add: string; added: string; none: string; edition: string } }) {
  const [q, setQ] = useState("");
  const [terms, setTerms] = useState<Array<{ basic_number: string; term: string }>>([]);
  const [open, setOpen] = useState(false);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const seq = useRef(0);

  useEffect(() => {
    if (!open) return;
    const mine = ++seq.current;
    const timer = setTimeout(() => {
      fetch(`/api/nice/terms?class=${classNumber}&lang=${lang}&q=${encodeURIComponent(q)}`, { credentials: "same-origin", cache: "no-store" })
        .then((r) => (r.ok ? r.json() : { terms: [] }))
        .then((d: { terms: Array<{ basic_number: string; term: string }> }) => { if (mine === seq.current) setTerms(d.terms ?? []); })
        .catch(() => {});
    }, 200);
    return () => clearTimeout(timer);
  }, [q, open, classNumber, lang]);

  const add = (term: string) => {
    const box = document.querySelector<HTMLTextAreaElement>(`textarea[name="${target}"]`);
    if (!box) return;
    const have = box.value.split(";").map((x) => x.trim().toLowerCase()).filter(Boolean);
    if (!have.includes(term.toLowerCase())) box.value = box.value.trim() ? `${box.value.trim().replace(/;$/, "")}; ${term}` : term;
    setPicked((p) => new Set(p).add(term));
  };

  return (
    <div className="term-picker">
      <input type="search" dir="auto" className="ms-input" placeholder={labels.search} value={q} aria-label={labels.search}
        onFocus={() => setOpen(true)} onChange={(e) => { setQ(e.target.value); setOpen(true); }} />
      {open ? (
        <ul className="term-picker__list">
          {terms.length === 0 ? <li className="ms-cap">{labels.none}</li> : terms.map((x) => (
            <li key={x.basic_number}>
              <span><span className="ms-cap num">{x.basic_number}</span> <span dir="auto">{x.term}</span></span>
              <button type="button" className="ms-btn ms-btn--sm ms-btn--quiet" onClick={() => add(x.term)}>{picked.has(x.term) ? labels.added : labels.add}</button>
            </li>
          ))}
        </ul>
      ) : null}
      <span className="ms-cap">{labels.edition}</span>
    </div>
  );
}
