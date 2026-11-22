/**
 * Reading a bulletin by its printed codes, without the AI reader (Founder ruling 22 Nov 2026, for large registries;
 * Türkiye first). Many offices print every entry with the international (WIPO ST.60) codes in front of each field:
 * (210) the application number, (220) its date, (731) the applicant, (540) the mark's wording, (511) the classes,
 * (510) the goods and services. Such a file is read from its own text, word by word with each word's place on the
 * page (pdftotext -bbox), so a value is copied exactly as the office wrote it and costs nothing to read.
 *
 * Nothing about a registry is written here: which code means what, the label of the agent line, the word that
 * stands for "figure only", the headings of the sections that publish applications, and the page geometry all come
 * from the source's settings (fetch_spec.read, data in the database).
 *
 * This module is pure (text in, entries out) so it can be checked against a whole bulletin outside the worker.
 */

export interface Word { x: number; y: number; x2: number; t: string }
export interface PageWords { width: number; height: number; words: Word[] }
export interface Line { page: number; col: number; x: number; y: number; left: number; text: string }

/** The source's settings for reading by codes (fetch_spec.read). Every value is data. */
export interface CodesSpec {
  codes: { number: string; filed?: string; applicant: string; mark: string; classes: string; goods: string; figure?: string };
  /** the label printed before the agent's name, as printed (for example "Vekil:") */
  agent_label?: string;
  /** a label inside the goods after which the office lists what was taken out of the application */
  excluded_label?: string;
  /** what the office prints in place of a wording for a mark that has none, and the kind of mark it means (for example "şekil": "device") */
  wording_kinds?: Record<string, string>;
  /** printed columns of an entry page, and the height of the running head in points */
  columns?: number;
  head_height?: number;
  /** pattern of an application number, used to recognise the lists of numbers printed before the entries */
  number_pattern?: string;
  /** the contents page: its heading, and the pattern a section title must match to be read */
  toc_heading?: string;
  sections?: string;
}

export interface CodesMark {
  page: number; page_to: number; printed_page: string | null;
  application_no: string | null; filing_date: string | null;
  mark_text_ar: string | null; mark_text_en: string | null; mark_type: string | null; has_image: boolean | null;
  classes: number[]; goods: string | null;
  applicant_name: string | null; applicant_country: string | null; applicant_address: string | null; applicant_ref: string | null; applicants: number | null;
  agent_name: string | null; agent_city: null;
  international_no: string | null; figure_codes: string | null; other: Record<string, string>;
  confidence: number; notes: string | null; read_by: "codes";
}

const unescapeXml = (s: string) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, "&");

/** The words of each page, with their place, from the output of `pdftotext -bbox`. */
export function pagesFromBbox(xml: string): PageWords[] {
  const pages: PageWords[] = [];
  const parts = xml.split(/<page /).slice(1);
  const word = /<word xMin="([\d.-]+)" yMin="([\d.-]+)" xMax="([\d.-]+)" yMax="[\d.-]+">([^<]*)<\/word>/g;
  for (const p of parts) {
    const size = /^width="([\d.]+)" height="([\d.]+)"/.exec(p);
    const words: Word[] = [];
    for (const m of p.matchAll(word)) words.push({ x: Number(m[1]), y: Number(m[2]), x2: Number(m[3]), t: unescapeXml(m[4]!) });
    pages.push({ width: size ? Number(size[1]) : 595, height: size ? Number(size[2]) : 842, words });
  }
  return pages;
}

/** The running head of a page (its words above the head height), as one text. */
export function headOf(page: PageWords, headHeight: number): string {
  return page.words.filter((w) => w.y < headHeight && !/^_+$/.test(w.t)).sort((a, b) => a.x - b.x).map((w) => w.t).join(" ");
}

/** The page number printed in the running head: the number standing alone at either end of it. */
export function printedPage(head: string): string | null {
  const t = head.trim().split(/\s+/);
  if (t.length && /^\d{1,6}$/.test(t[0]!)) return t[0]!;
  if (t.length && /^\d{1,6}$/.test(t[t.length - 1]!)) return t[t.length - 1]!;
  return null;
}

/**
 * The lines of a page in reading order: column by column, top to bottom. Words are put in a column by where they
 * begin, and words at the same height in the same column make one line. `left` is the column's own left edge on
 * this page, so a line's indent can be told.
 */
export function linesOf(page: PageWords, pageNo: number, columns: number, headHeight: number): Line[] {
  const body = page.words.filter((w) => w.y >= headHeight && !/^_{5,}$/.test(w.t));
  const colWidth = page.width / columns;
  const out: Line[] = [];
  for (let c = 0; c < columns; c++) {
    const words = body.filter((w) => Math.min(columns - 1, Math.floor(w.x / colWidth)) === c).sort((a, b) => a.y - b.y || a.x - b.x);
    if (words.length === 0) continue;
    const left = Math.min(...words.map((w) => w.x));
    let line: Word[] = []; let y = -100;
    const flush = () => {
      if (!line.length) return;
      line.sort((a, b) => a.x - b.x);
      out.push({ page: pageNo, col: c, x: line[0]!.x, y, left, text: line.map((w) => w.t).join(" ") });
      line = [];
    };
    for (const w of words) {
      if (Math.abs(w.y - y) > 3) { flush(); y = w.y; }
      line.push(w);
    }
    flush();
  }
  return out;
}

/** The sections of a bulletin from its contents page: title and first page, in order. Titles may run over two lines. */
export function sectionsFromContents(text: string): Array<{ title: string; page: number }> {
  const out: Array<{ title: string; page: number }> = [];
  let pending = "";
  for (const raw of text.split("\n")) {
    const l = raw.trim();
    if (!l) continue;
    const m = /^(.*?)\s*(?:\.\s?){3,}\s*(\d{1,6})$/.exec(l);
    if (m) { out.push({ title: `${pending} ${m[1]}`.replace(/\s+/g, " ").trim(), page: Number(m[2]) }); pending = ""; }
    else pending = `${pending} ${l}`.trim();
  }
  return out;
}

/** The page ranges to read: the sections whose title matches the source's pattern, each up to the page before the next section. */
export function rangesToRead(sections: Array<{ title: string; page: number }>, pattern: string, pageCount: number): Array<{ title: string; from: number; to: number }> {
  let re: RegExp;
  try { re = new RegExp(pattern, "i"); } catch { return []; }
  const s = [...sections].sort((a, b) => a.page - b.page);
  const out: Array<{ title: string; from: number; to: number }> = [];
  s.forEach((x, i) => {
    if (!re.test(x.title) || x.page < 1 || x.page > pageCount) return;
    const to = Math.min(pageCount, i + 1 < s.length ? s[i + 1]!.page - 1 : pageCount);
    if (to >= x.page) out.push({ title: x.title, from: x.page, to });
  });
  return out;
}

const iso = (d: string): string | null => {
  const m = /^(\d{1,2})[./-](\d{1,2})[./-](\d{4})$/.exec(d.trim());
  return m ? `${m[3]}-${m[2]!.padStart(2, "0")}-${m[1]!.padStart(2, "0")}` : null;
};

type Field = "applicant" | "agent" | "mark" | "figure" | "classes" | "goods" | "other" | null;

interface Draft {
  page: number; pageTo: number; printed: string | null; no: string | null; filed: string | null; filedRaw: string | null;
  names: string[][]; addresses: string[][]; agent: string[]; mark: string[]; figure: string[]; classes: string[]; goods: string[]; excluded: string[] | null;
  other: Record<string, string[]>; otherCode: string; intl: string | null; seen: Set<string>; lastGoodsLoose: boolean;
}

/**
 * Reads entries from lines given page after page. An entry begins at the line that starts with the number code and
 * runs to the next such line (or to the end of the section). Lines before the first entry of a section are the
 * office's own list of the numbers published in it; they are collected for the comparison.
 */
export class CodesReader {
  private d: Draft | null = null;
  private field: Field = null;
  private readonly code: RegExp;
  private readonly numberRe: RegExp;
  private readonly kinds: Map<string, string>;
  // the office's customer number before a name: six digits or more, a dash, a letter (a postal code such as 46542-2000 is not one)
  private readonly refStart = /^\d{6,10}\s*-\s*\p{L}/u;
  private prev: Line | null = null;
  private readonly spec: CodesSpec;
  readonly index: string[] = [];
  /** lines met before the first entry that are neither numbers nor a heading are counted, not kept */
  skippedBefore = 0;

  constructor(spec: CodesSpec) {
    this.spec = spec;
    this.code = /^\((\d{3})\)\s*(.*)$/;
    let n: RegExp;
    try { n = new RegExp(spec.number_pattern ?? "\\d{4}/\\d{3,7}", "g"); } catch { n = /\d{4}\/\d{3,7}/g; }
    this.numberRe = n;
    this.kinds = new Map(Object.entries(spec.wording_kinds ?? {}).map(([w, k]) => [w.toLocaleLowerCase("tr"), k]));
  }

  /** Give one page's lines; returns the entries that ended on it. */
  feed(lines: Line[], printed: string | null): CodesMark[] {
    const done: CodesMark[] = [];
    const c = this.spec.codes;
    for (const l of lines) {
      const text = l.text.trim();
      if (!text) continue;
      const m = this.code.exec(text);
      if (m && m[1] === c.number) {
        // a number standing alone and indented just above is the international registration's number
        let intl: string | null = null;
        if (this.prev && /^\d{5,8}[A-Z]?$/.test(this.prev.text.trim()) && this.prev.x - this.prev.left > 30) {
          intl = this.prev.text.trim();
          if (this.d && this.d.lastGoodsLoose) { (this.d.excluded ?? this.d.goods).pop(); }
        }
        if (this.d) done.push(this.finish(this.d));
        this.d = { page: l.page, pageTo: l.page, printed, no: null, filed: null, filedRaw: null, names: [], addresses: [], agent: [], mark: [], figure: [], classes: [], goods: [],
                   excluded: null, other: {}, otherCode: "", intl, seen: new Set([c.number]), lastGoodsLoose: false };
        let rest = m[2] ?? "";
        if (c.filed) {
          const f = new RegExp(`\\(${c.filed}\\)\\s*(\\S+)`).exec(rest);
          if (f) { this.d.filedRaw = f[1]!; this.d.filed = iso(f[1]!); this.d.seen.add(c.filed); rest = rest.slice(0, f.index); }
        }
        this.d.no = rest.trim() || null;
        this.field = null; this.prev = l;
        continue;
      }
      if (!this.d) {
        // before the first entry: the office's list of numbers
        const found = text.match(this.numberRe);
        if (found) this.index.push(...found); else this.skippedBefore += 1;
        this.prev = l;
        continue;
      }
      const d = this.d;
      d.pageTo = l.page; d.lastGoodsLoose = false;
      if (m) {
        const [, code, restRaw] = m; const rest = (restRaw ?? "").trim();
        d.seen.add(code!);
        if (code === c.filed) { d.filedRaw = rest; d.filed = iso(rest.split(/\s+/)[0] ?? ""); this.field = null; }
        else if (code === c.applicant) { d.names.push(rest ? [rest] : []); d.addresses.push([]); this.field = "applicant"; }
        else if (code === c.mark) { if (rest) d.mark.push(rest); this.field = "mark"; }
        else if (code === c.classes) { if (rest) d.classes.push(rest); this.field = "classes"; }
        else if (code === c.goods) { if (rest) d.goods.push(rest); this.field = "goods"; }
        else if (c.figure && code === c.figure) { if (rest) d.figure.push(rest); this.field = "figure"; }
        else { d.other[code!] = rest ? [rest] : []; d.otherCode = code!; this.field = "other"; }
        this.prev = l;
        continue;
      }
      if (this.spec.agent_label && text.startsWith(this.spec.agent_label) && this.field !== "goods") {
        const rest = text.slice(this.spec.agent_label.length).trim();
        if (rest) d.agent.push(rest);
        this.field = "agent"; this.prev = l;
        continue;
      }
      switch (this.field) {
        case "applicant": {
          // a name ends with the country in brackets; what follows it is the address. A further applicant begins
          // with the office's customer number, as the first one does.
          const name = d.names[d.names.length - 1]!; const address = d.addresses[d.addresses.length - 1]!;
          const closed = address.length > 0 || /\([A-Z]{2}\)\s*$/.test(name.join(" "));
          if (closed && this.refStart.test(text) && this.refStart.test(d.names[0]!.join(" "))) { d.names.push([text]); d.addresses.push([]); }
          else if (closed) address.push(text); else name.push(text);
          break;
        }
        case "agent": d.agent.push(text); break;
        case "mark": d.mark.push(text); break;
        case "figure": d.figure.push(text); break;
        case "classes": if (/^[\d\s,]+$/.test(text)) d.classes.push(text); else d.other.unplaced = [...(d.other.unplaced ?? []), text]; break;
        case "goods":
          if (this.spec.excluded_label && text.startsWith(this.spec.excluded_label)) {
            d.excluded = [];
            const rest = text.slice(this.spec.excluded_label.length).trim();
            if (rest) d.excluded.push(rest);
          } else { (d.excluded ?? d.goods).push(text); d.lastGoodsLoose = true; }
          break;
        case "other": d.other[d.otherCode]!.push(text); break;
        default: d.other.unplaced = [...(d.other.unplaced ?? []), text];
      }
      this.prev = l;
    }
    return done;
  }

  /** The entry still open when the pages end. */
  end(): CodesMark[] {
    if (!this.d) return [];
    const m = this.finish(this.d);
    this.d = null; this.field = null;
    return [m];
  }

  private finish(d: Draft): CodesMark {
    const c = this.spec.codes;
    const join = (a: string[]) => a.join(" ").replace(/\s+/g, " ").trim();
    // each applicant: the office's own customer number, the name, the country in brackets
    const people = d.names.map((n) => {
      let name = join(n);
      const country = /\(([A-Z]{2})\)\s*$/.exec(name)?.[1] ?? null;
      if (country) name = name.replace(/\s*\([A-Z]{2}\)\s*$/, "");
      const ref = /^(\d{3,})\s*-\s*/.exec(name);
      if (ref) name = name.slice(ref[0].length);
      return { name, country, ref: ref ? ref[1]! : null };
    }).filter((x) => x.name);
    const applicant = people.map((x) => x.name).join("; ");
    const country = people[0]?.country ?? null;
    const ref = people.map((x) => x.ref).filter(Boolean).join(", ") || null;
    const wording = join(d.mark);
    // a word the office prints in place of a wording (figure only, sound mark …) is the kind of mark, not its wording
    const kind = wording ? this.kinds.get(wording.toLocaleLowerCase("tr")) ?? null : null;
    const classes = [...new Set(join(d.classes).split(/[^\d]+/).filter(Boolean).map(Number).filter((n) => n >= 1 && n <= 45))].sort((a, b) => a - b);
    let goods = join(d.goods);
    if (d.excluded) goods = `${goods}\n\n${this.spec.excluded_label} ${join(d.excluded)}`.trim();
    const missing: string[] = [];
    if (!d.no) missing.push("number");
    if (!d.seen.has(c.applicant) || !applicant) missing.push("applicant");
    if (!d.seen.has(c.mark)) missing.push("wording");
    if (!d.seen.has(c.classes) || classes.length === 0) missing.push("classes");
    if (!d.seen.has(c.goods) || !goods) missing.push("goods");
    if (d.filedRaw && !d.filed) missing.push("date");
    const other: Record<string, string> = {};
    for (const [k, v] of Object.entries(d.other)) if (v.length) other[k] = join(v);
    const notes = [missing.length ? `not found in the entry: ${missing.join(", ")}` : null, other.unplaced ? "text that belongs to no field was found in the entry" : null].filter(Boolean).join("; ");
    return {
      page: d.page, page_to: d.pageTo, printed_page: d.printed,
      application_no: d.no, filing_date: d.filed,
      mark_text_ar: null, mark_text_en: kind || !wording ? null : wording.slice(0, 300),
      mark_type: kind ?? (d.figure.length ? "combined" : null), has_image: kind === "device" || d.figure.length > 0 ? true : null,
      classes, goods: goods || null,
      applicant_name: applicant || null, applicant_country: country, applicant_address: d.addresses.map(join).filter(Boolean).join("; ") || null, applicant_ref: ref,
      applicants: people.length > 1 ? people.length : null,
      agent_name: join(d.agent).replace(/\s*\(null\)\s*$/, "") || null, agent_city: null,
      international_no: d.intl, figure_codes: join(d.figure) || null, other,
      confidence: missing.length || other.unplaced ? 0.5 : 1, notes: notes || null, read_by: "codes",
    };
  }
}
