import type { ReactNode } from "react";
import { CONSENT_DOCUMENTS, LEGAL_DOCS, LEGAL_VERSION, type LegalSlug } from "@/content/legal.generated";

/**
 * The legal texts shown in the product. Their wording comes, unaltered, from the documents of record in
 * docs/03-legal (converted by infra/tools/legal2md.py); nothing here rewords them.
 */
export { CONSENT_DOCUMENTS, LEGAL_DOCS, LEGAL_VERSION };
export type { LegalSlug };
export const LEGAL_SLUGS = Object.keys(LEGAL_DOCS) as LegalSlug[];
export const isLegalSlug = (v: string): v is LegalSlug => (LEGAL_SLUGS as string[]).includes(v);

/** The cookies this build sets, for the Cookie Notice page. Kept beside the code that sets them. */
export const COOKIES_IN_USE: Array<{ name: string; purpose: "session" | "challenge" | "passOnce" | "passHold" | "calendarOnce" | "notice"; life: string }> = [
  { name: "msm_session", purpose: "session", life: "30 d" },
  { name: "ms_2fa", purpose: "challenge", life: "15 min" },
  { name: "ms_pass_<id>", purpose: "passOnce", life: "5 min" },
  { name: "ms_pass_hold", purpose: "passHold", life: "7 d" },
  { name: "ms_cal", purpose: "calendarOnce", life: "10 min" },
  { name: "ms_cookie_ok", purpose: "notice", life: "12 mo" },
];

const inline = (s: string): ReactNode[] => s.split(/(\*\*[^*]+\*\*)/g).map((p, i) => (p.startsWith("**") && p.endsWith("**") ? <b key={i}>{p.slice(2, -2)}</b> : p));
const cells = (line: string) => line.replace(/^\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim());

/** Renders the limited Markdown the converter writes: section headings, numbered clauses, lists and tables. */
export function LegalBody({ body }: { body: string }) {
  const out: ReactNode[] = [];
  const lines = body.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i]!;
    if (!l.trim() || l.startsWith("# ")) continue;   // the page already carries the title
    if (l.startsWith("## ")) { out.push(<h2 key={i}>{l.slice(3)}</h2>); continue; }
    if (l.startsWith("| ")) {
      const head = cells(l);
      const rows: string[][] = [];
      let j = i + 2;
      while (j < lines.length && lines[j]!.startsWith("| ")) { rows.push(cells(lines[j]!)); j++; }
      out.push(
        <div key={i} className="legal-table"><table>
          <thead><tr>{head.map((h, k) => <th key={k} scope="col">{h}</th>)}</tr></thead>
          <tbody>{rows.map((r, k) => <tr key={k}>{r.map((c, m) => <td key={m}>{c}</td>)}</tr>)}</tbody>
        </table></div>);
      i = j - 1;
      continue;
    }
    if (l.startsWith("- ")) {
      const items: string[] = [];
      let j = i;
      while (j < lines.length && lines[j]!.startsWith("- ")) { items.push(lines[j]!.slice(2)); j++; }
      out.push(<ul key={i}>{items.map((x, k) => <li key={k}>{inline(x)}</li>)}</ul>);
      i = j - 1;
      continue;
    }
    out.push(<p key={i}>{inline(l)}</p>);
  }
  return <>{out}</>;
}
