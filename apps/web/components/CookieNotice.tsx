"use client";
import { useEffect, useState } from "react";

/**
 * First-visit cookie notice. This build sets only the cookies needed to sign in and to work (listed on the
 * Cookie Notice page), so there is nothing to refuse; the bar says so and is not shown again once read.
 */
export function CookieNotice({ text, more, ok, href }: { text: string; more: string; ok: string; href: string }) {
  const [show, setShow] = useState(false);
  useEffect(() => { setShow(!document.cookie.split("; ").some((c) => c.startsWith("ms_cookie_ok="))); }, []);
  if (!show) return null;
  const close = () => { document.cookie = `ms_cookie_ok=1; path=/; max-age=${365 * 24 * 3600}; samesite=lax`; setShow(false); };
  return (
    <div className="cookie-bar" role="region" aria-label={more}>
      <span>{text} <a href={href}>{more}</a></span>
      <button type="button" className="ms-btn ms-btn--sm" onClick={close}>{ok}</button>
    </div>
  );
}
