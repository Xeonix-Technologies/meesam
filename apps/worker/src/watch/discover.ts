/**
 * Watch, stage 1 — discovery (MSM-PRD-02 Section 4, fetcher type "page crawler": links on a page).
 * Pure functions, no network: given the page and the source's catalogue row, list the issues the page offers.
 * Everything registry-specific is data in the catalogue row (fetch_spec); adding a registry of this type is
 * configuration, not code.
 */
export interface SourceSpec {
  url: string;
  fetcher?: string;
  /** regular expression an issue link's address must match */
  link_href?: string;
  /** regular expression with one group: the issue number, read from the link text or its address; when absent, the file's name is the issue */
  issue_no?: string;
  /** regular expression with three groups: day, month and year, in the order `date_order` names */
  date?: string;
  /** where the issue number and date stand when they are not in the link itself: "after" the link (default) or "before" it (a table row: number, date, then the links) */
  context?: "after" | "before";
  /** how many of the newest issues to take when the registry's opposition period is not verified, so no window can be computed */
  take_latest?: number;
  /** the order of the three groups in `date`: "dmy" (default), "mdy" or "ymd" */
  date_order?: DateOrder;
  /** what the downloaded file is: rar, zip, pdf */
  container?: string;
  max_per_run?: number;
  min_bytes?: number;
  max_bytes?: number;
}

/** Fields of a "pattern" source: numbered addresses, no page to read (MSM-PRD-02 Section 4, pattern fetcher). */
export interface PatternSpec {
  /** the file's address with {issue} where the issue number goes, e.g. https://…/tm-journals/{issue}/jnl.pdf */
  pattern?: string;
  /** an issue known to exist, as year-number (2026-046): the first one taken, and the shape of the numbering */
  start_issue?: string;
}

export interface ListedIssue {
  issueNo: string;
  publishedOn: string | null;   // ISO date, or null when the page gives none
  url: string;
  title: string;
  /** a guess at the next number: "not there yet" (404) is the normal answer, not a failure */
  probe?: boolean;
}

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const entities = (s: string) => s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#0?39;|&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ");
const textOf = (html: string) => entities(html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
const decoded = (u: string) => { try { return decodeURIComponent(u); } catch { return u; } };

export type DateOrder = "dmy" | "mdy" | "ymd";

/**
 * Reads a date with the catalogue's pattern. The pattern has three groups, in the order the catalogue names:
 * "dmy" (17 Nov 2026, the default), "mdy" (October 15, 2026) or "ymd" (2026-10-15). The month may be an English
 * name or a number.
 */
export function parseDate(text: string, pattern: string | undefined, order: DateOrder = "dmy"): string | null {
  if (!pattern) return null;
  const m = new RegExp(pattern, "i").exec(text);
  if (!m) return null;
  const at = { d: order.indexOf("d") + 1, m: order.indexOf("m") + 1, y: order.indexOf("y") + 1 };
  const day = Number(m[at.d]);
  const rawMonth = String(m[at.m] ?? "");
  const month = /^\d+$/.test(rawMonth) ? Number(rawMonth) - 1 : MONTHS.indexOf(rawMonth.slice(0, 3).toLowerCase());
  const year = Number(m[at.y]);
  if (!(day >= 1 && day <= 31) || !(month >= 0 && month <= 11) || !(year >= 1990 && year <= 2100)) return null;
  const d = new Date(Date.UTC(year, month, day));
  if (d.getUTCDate() !== day) return null;       // 31 Feb and the like
  return d.toISOString().slice(0, 10);
}

/** The issues linked on the page, in page order (registries list newest first). */
export function discoverLinks(html: string, spec: SourceSpec): ListedIssue[] {
  const hrefRe = new RegExp(spec.link_href ?? "\\.(pdf|rar|zip)(/|$|\\?)", "i");
  const issueRe = spec.issue_no ? new RegExp(spec.issue_no, "i") : null;
  const anchor = /<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)<\/a>/gi;
  const found: Array<{ url: string; text: string; start: number; end: number }> = [];
  for (let m = anchor.exec(html); m; m = anchor.exec(html)) {
    const raw = entities(m[1] ?? m[2] ?? "").trim();
    if (!raw || !hrefRe.test(decoded(raw))) continue;
    let url: string;
    try { url = new URL(raw, spec.url).toString(); } catch { continue; }
    if (!/^https?:$/.test(new URL(url).protocol)) continue;
    found.push({ url, text: textOf(m[3] ?? ""), start: m.index, end: anchor.lastIndex });
  }
  const out: ListedIssue[] = [];
  const seenUrl = new Set<string>();
  const seenNo = new Map<string, number>();
  found.forEach((f, i) => {
    if (seenUrl.has(f.url)) return;
    seenUrl.add(f.url);
    // some pages put the number and date beside the link, not inside it: after it (up to the next issue link),
    // or before it in the same table row (back to the previous issue link). Before the link, the nearest wins.
    const before = spec.context === "before";
    const near = before
      ? textOf(html.slice(Math.max(found[i - 1]?.end ?? 0, f.start - 600), f.start)).slice(-200)
      : textOf(html.slice(f.end, Math.min(found[i + 1]?.start ?? f.end + 600, f.end + 600))).slice(0, 200);
    const pick = (re: RegExp | null, text: string) => { if (!re) return null; const all = [...text.matchAll(new RegExp(re.source, "gi"))]; return (before ? all[all.length - 1] : all[0]) ?? null; };
    const name = decoded(f.url.split("/").find((p) => hrefRe.test(decoded(p)) || hrefRe.test(decoded(p) + "/")) ?? "");
    // a "current issue" page names no number: with no issue pattern in the catalogue, the file's own name is the issue
    const no = issueRe
      ? (issueRe.exec(f.text) ?? issueRe.exec(name) ?? pick(issueRe, near))?.[1] ?? null
      : name.replace(/\.[A-Za-z0-9]{2,5}$/, "").replace(/\s+/g, " ").trim().slice(0, 80) || null;
    if (!no) return;                              // a link that names no issue is not an issue
    const nearDate = spec.date ? pick(new RegExp(spec.date), near)?.[0] ?? "" : "";
    const publishedOn = parseDate(f.text, spec.date, spec.date_order) ?? parseDate(nearDate, spec.date, spec.date_order);
    const n = (seenNo.get(no) ?? 0) + 1;
    seenNo.set(no, n);
    out.push({ issueNo: n === 1 ? no : `${no} (${n})`, publishedOn, url: f.url, title: f.text.slice(0, 200) || name.slice(0, 200) });
  });
  return out;
}

export { contentTypeOf, issueKey, shapeProblem } from "@meesam/db";

/**
 * Pattern fetcher: the issues to ask for when a registry numbers its files year-number and serves each at a
 * predictable address. Nothing held yet: the known starting issue. Otherwise the number after the newest one
 * held, and number 1 of the current year once the year has turned (the numbering starts again each January).
 */
export function patternCandidates(spec: PatternSpec, held: string[], today = new Date()): ListedIssue[] {
  const start = /^(\d{4})-(\d+)$/.exec(spec.start_issue ?? "");
  if (!spec.pattern || !spec.pattern.includes("{issue}") || !start) return [];
  const width = start[2]!.length;
  const make = (year: number, n: number, probe: boolean): ListedIssue => {
    const issueNo = `${year}-${String(n).padStart(width, "0")}`;
    return { issueNo, publishedOn: null, url: spec.pattern!.replace("{issue}", issueNo), title: issueNo, probe };
  };
  const have = held.map((h) => /^(\d{4})-(\d+)$/.exec(h)).filter((m): m is RegExpExecArray => !!m).map((m) => [Number(m[1]), Number(m[2])] as const)
    .sort((a, b) => b[0] - a[0] || b[1] - a[1]);
  const newest = have[0];
  if (!newest) return [make(Number(start[1]), Number(start[2]), false)];
  const out = [make(newest[0], newest[1] + 1, true)];
  const year = today.getUTCFullYear();
  if (year > newest[0]) out.push(make(year, 1, true));
  return out;
}
