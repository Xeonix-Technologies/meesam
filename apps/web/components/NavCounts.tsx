"use client";
import { createContext, Suspense, useContext, useEffect, useState, type ReactNode } from "react";
import { usePathname, useSearchParams } from "next/navigation";

/**
 * Live counts for the side navigation (appointment requests to answer, unread messages per record).
 * The app layout is rendered once and kept while the user moves between pages, so counts drawn on the
 * server would go stale (a message stays "unread" after it was opened). These are re-read from the server
 * after every navigation, including a change of tab on the same page.
 */
export interface Counts { requests: number; unread: Record<string, number> }
const Ctx = createContext<Counts>({ requests: 0, unread: {} });

function Watcher({ onChange }: { onChange: (c: Counts) => void }) {
  const path = usePathname();
  const search = useSearchParams()?.toString() ?? "";
  useEffect(() => {
    let live = true;
    fetch("/api/nav/counts", { cache: "no-store", credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : null))
      .then((c: Counts | null) => { if (live && c) onChange(c); })
      .catch(() => {});
    return () => { live = false; };
  }, [path, search, onChange]);
  return null;
}

export function NavCountsProvider({ initial, children }: { initial: Counts; children: ReactNode }) {
  const [counts, setCounts] = useState<Counts>(initial);
  return (
    <Ctx.Provider value={counts}>
      <Suspense fallback={null}><Watcher onChange={setCounts} /></Suspense>
      {children}
    </Ctx.Provider>
  );
}

/** Count of appointment requests waiting for this account's answer; nothing when zero. */
export function RequestsBadge({ label }: { label: string }) {
  const { requests } = useContext(Ctx);
  return requests > 0 ? <span className="nav-badge" title={label.replace("{n}", String(requests))}>{requests}</span> : null;
}

/** Unread messages on one record; shows `children` (the registry code) when there are none. */
export function UnreadBadge({ recordId, label, children }: { recordId: string; label: string; children: ReactNode }) {
  const n = useContext(Ctx).unread[recordId] ?? 0;
  return n > 0 ? <span className="nav-badge" title={label.replace("{n}", String(n))}>{n}</span> : <>{children}</>;
}
