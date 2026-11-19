"use client";
import { useEffect, useState } from "react";

/**
 * A moment shown in the reader's own time zone, with the zone named (Founder ruling 18 Nov 2026). The server
 * does not know the reader's zone, so it renders `fallback` (Gulf Standard Time) and the browser replaces it.
 */
export function LocalTime({ iso, locale, fallback, timeOnly = false }: { iso: string; locale: string; fallback: string; timeOnly?: boolean }) {
  const [text, setText] = useState(fallback);
  useEffect(() => {
    try {
      const day = timeOnly ? {} : ({ day: "2-digit", month: "short", year: "numeric" } as const);
      setText(new Intl.DateTimeFormat(locale === "ar" ? "ar-AE-u-nu-latn" : "en-GB", { ...day, hour: "2-digit", minute: "2-digit", hour12: false, timeZoneName: "short" }).format(new Date(iso)));
    } catch { /* keep the server's rendering */ }
  }, [iso, locale, timeOnly]);
  return <time className="num" dateTime={iso} suppressHydrationWarning>{text}</time>;
}
