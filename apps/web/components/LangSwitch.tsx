"use client";
import { Suspense } from "react";
import { usePathname, useSearchParams } from "next/navigation";

/**
 * The language switch of the signed-in areas. It keeps the reader on the same page, with the same item open
 * (found on staging, 22 Nov 2026: switching language in the reviewer's queue went back to the console's first
 * page). One-time notices ("saved", "error") are not carried over. `fallback` is the area's home in the other
 * language, used until the address is known.
 */
function Inner({ locale, other, label, fallback }: { locale: string; other: string; label: string; fallback: string }) {
  const path = usePathname() ?? "";
  const query = new URLSearchParams(useSearchParams()?.toString() ?? "");
  query.delete("saved"); query.delete("error");
  const here = path === `/${locale}` || path.startsWith(`/${locale}/`) ? `/${other}${path.slice(locale.length + 1)}` : fallback;
  const qs = query.toString();
  // a full page load: the document's language and direction change with the address
  return <a href={qs ? `${here}?${qs}` : here} hrefLang={other} lang={other} className="ms-langbtn">{label}</a>;
}

export function LangSwitch(p: { locale: string; other: string; label: string; fallback: string }) {
  return <Suspense fallback={<a href={p.fallback} hrefLang={p.other} lang={p.other} className="ms-langbtn">{p.label}</a>}><Inner {...p} /></Suspense>;
}
