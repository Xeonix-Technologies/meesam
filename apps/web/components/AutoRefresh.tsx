"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";

/**
 * Keeps a page's figures fresh while work is in progress (a reading, a comparison): the page's data is read again
 * every few seconds for as long as this is on the page. It stops the moment the reader moves to another page
 * (found on staging, 22 Nov 2026: the earlier whole-page refresh pulled the reader back to the page he had left).
 */
export function AutoRefresh({ seconds }: { seconds: number }) {
  const router = useRouter();
  useEffect(() => {
    const id = setInterval(() => { if (document.visibilityState === "visible") router.refresh(); }, Math.max(3, seconds) * 1000);
    return () => clearInterval(id);
  }, [router, seconds]);
  return null;
}
