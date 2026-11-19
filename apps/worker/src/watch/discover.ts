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
  /** regular expression with one group: the issue number, read from the link text or its address */
  issue_no?: string;
  /** regular expression with three groups: day, month name (English, three letters or more), year */
  date?: string;
  /** what the downloaded file is: rar, zip, pdf */
  container?: string;
  max_per_run?: number;
  min_bytes?: number;
  max_bytes?: number;
}

export interface ListedIssue {
  issueNo: string;
  publishedOn: string | null;   // ISO date, or null when the page gives none
  url: string;
  title: string;
}

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const entities = (s: string) => s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#0?39;|&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ");
const textOf = (html: string) => entities(html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
const decoded = (u: string) => { try { return decodeURIComponent(u); } catch { return u; } };

export function parseDate(text: string, pattern: string | undefined): string | null {
  if (!pattern) return null;
  const m = new RegExp(pattern, "i").exec(text);
  if (!m) return null;
  const day = Number(m[1]);
  const month = MONTHS.indexOf(String(m[2]).slice(0, 3).toLowerCase());
  const year = Number(m[3]);
  if (!(day >= 1 && day <= 31) || month < 0 || !(year >= 1990 && year <= 2100)) return null;
  const d = new Date(Date.UTC(year, month, day));
  if (d.getUTCDate() !== day) return null;       // 31 Feb and the like
  return d.toISOString().slice(0, 10);
}

/** The issues linked on the page, in page order (registries list newest first). */
export function discoverLinks(html: string, spec: SourceSpec): ListedIssue[] {
  const hrefRe = new RegExp(spec.link_href ?? "\\.(pdf|rar|zip)(/|$|\\?)", "i");
  const issueRe = spec.issue_no ? new RegExp(spec.issue_no, "i") : null;
  const anchor = /<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)<\/a>/gi;
  const found: Array<{ url: string; text: string; end: number }> = [];
  for (let m = anchor.exec(html); m; m = anchor.exec(html)) {
    const raw = entities(m[1] ?? m[2] ?? "").trim();
    if (!raw || !hrefRe.test(decoded(raw))) continue;
    let url: string;
    try { url = new URL(raw, spec.url).toString(); } catch { continue; }
    if (!/^https?:$/.test(new URL(url).protocol)) continue;
    found.push({ url, text: textOf(m[3] ?? ""), end: anchor.lastIndex });
  }
  const out: ListedIssue[] = [];
  const seenUrl = new Set<string>();
  const seenNo = new Map<string, number>();
  found.forEach((f, i) => {
    if (seenUrl.has(f.url)) return;
    seenUrl.add(f.url);
    // some pages put the date beside the link, not inside it: read on up to the next issue link
    const after = textOf(html.slice(f.end, Math.min(found[i + 1]?.end ?? f.end + 600, f.end + 600))).slice(0, 200);
    const name = decoded(f.url.split("/").find((p) => hrefRe.test(decoded(p) + "/")) ?? "");
    const no = (issueRe?.exec(f.text) ?? issueRe?.exec(name))?.[1] ?? null;
    if (!no) return;                              // a link that names no issue is not an issue
    const publishedOn = parseDate(f.text, spec.date) ?? parseDate(after, spec.date);
    const n = (seenNo.get(no) ?? 0) + 1;
    seenNo.set(no, n);
    out.push({ issueNo: n === 1 ? no : `${no} (${n})`, publishedOn, url: f.url, title: f.text.slice(0, 200) || name.slice(0, 200) });
  });
  return out;
}

const MAGIC: Record<string, number[]> = {
  rar: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07],
  zip: [0x50, 0x4b, 0x03, 0x04],
  pdf: [0x25, 0x50, 0x44, 0x46],
};

/**
 * The shape check on a downloaded file (Section 4): it is the kind of file the catalogue expects, of a plausible
 * size, and its date is not in the future. Returns the reason it fails, or null when it passes. (The mark-count
 * range of Section 4 is checked after extraction, when the marks are known.)
 */
export function shapeProblem(head: Uint8Array, bytes: number, publishedOn: string | null, spec: SourceSpec, today = new Date()): string | null {
  const kind = (spec.container ?? "pdf").toLowerCase();
  const magic = MAGIC[kind];
  if (!magic) return `the catalogue names an unknown file kind: ${kind}`;
  if (!magic.every((b, i) => head[i] === b)) return `the file is not a ${kind.toUpperCase()} file (the site may have answered with a page)`;
  const min = spec.min_bytes ?? 20 * 1024;
  if (bytes < min) return `the file is too small to be an issue: ${bytes} bytes`;
  if (publishedOn && new Date(`${publishedOn}T00:00:00Z`).getTime() > today.getTime() + 36 * 3600 * 1000) return `the issue date ${publishedOn} is in the future`;
  return null;
}

export const contentTypeOf = (container: string): string =>
  ({ rar: "application/vnd.rar", zip: "application/zip", pdf: "application/pdf" })[container.toLowerCase()] ?? "application/octet-stream";

/** Where an issue is kept in the publications bucket: registry / stream / number and the start of its checksum. */
export function issueKey(registry: string, stream: string, issueNo: string, sha256Hex: string, container: string): string {
  const safe = issueNo.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "") || "issue";
  return `${registry}/${stream}/${safe}_${sha256Hex.slice(0, 12)}.${container.toLowerCase().replace(/[^a-z0-9]/g, "")}`;
}
