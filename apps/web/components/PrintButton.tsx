"use client";

/** Opens the browser's print dialog (the prepared filing request is printed or saved as PDF from there). */
export function PrintButton({ label }: { label: string }) {
  return <button type="button" className="ms-btn ms-btn--quiet no-print" onClick={() => window.print()}>{label}</button>;
}
