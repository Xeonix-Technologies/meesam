/**
 * Reading a bulletin by its printed labels, without the AI reader (Founder ruling 22 Nov 2026 on reading by rules;
 * the UAE, 24 Nov 2026). Some offices print every notice on a form: the same labels in the same places, each followed
 * by its value ("المودعة بالرقم : 372719", "Holder's Name: …"), or print a list as a table. Such a file is read from
 * its own text, word by word with each word's place on the page (pdftotext -bbox), so a value is copied as the
 * office wrote it and costs nothing to read.
 *
 * Nothing about a registry is written here: the title that tells which form a file holds, the labels, where the two
 * columns of a form part, the line under which a form changes its columns, the columns of a table — all of it comes
 * from the source's settings (fetch_spec.read.forms, data in the database).
 *
 * Arabic: pdftotext gives the letters of a word in the order they stand on the page (left to right). A word with an
 * Arabic letter is turned round here. (The joined letters "لا" need the file prepared first, see read-labels.ts.)
 *
 * This module is pure (text in, entries out) so it can be checked against a whole bulletin outside the worker.
 */

export interface LWord { x: number; y: number; x2: number; h: number; t: string }
export interface LPage { width: number; height: number; words: LWord[] }

/** `inline`: the label stands on the line of that other field ("بتاريخ" on the line of the number), not at the start of a line */
/** `top` (centred forms): this label stands on the FIRST line of its value, not beside its middle */
export interface LabelDef { label: string; field: string; inline?: string; top?: boolean }
export interface FormSpec {
  /** a short name for the part ("accepted", "madrid", "renewals") and what its entries are */
  key: string;
  /** the settings of another form are taken, and what is written here replaces them (forms that differ only by title) */
  like?: string;
  kind: "marks" | "notices";
  /** pattern tested against the opening text of the file's first page, written without spaces */
  title: string;
  /**
   * "centred": a form laid out as a table whose label stands beside the MIDDLE of its value (Egypt), so lines of a
   * value stand above its label as well as under it. The lines of a value are told by their place: as far above
   * the label as below it.
   */
  layout: "columns" | "plain" | "centred" | "table";
  /** the line every entry begins with, as printed (forms); a word taller than title_height is part of it */
  start?: string;
  /** the entry's first line is exactly `start`, nothing after it (a heading that is also an ordinary word of the text) */
  start_exact?: boolean;
  title_height?: number;
  /** text above `top` and below `bottom` (points from the top of the page) is the running head and foot */
  top?: number;
  bottom?: number;
  /** two-column forms: a word that ends at or before this place is in the left column; `break` is the line under which the lower value applies */
  split?: { upper: number; lower: number };
  break?: string;
  labels?: LabelDef[];
  /** lines that belong to no field and are not kept (the opening words of the form) */
  skip?: string[];
  /** the sentence that closes a notice; what follows it belongs to no field */
  end?: string;
  /** lines that follow the label line of a field are another field (the class is on the label line, the goods follow) */
  then?: Record<string, string>;
  /**
   * lines told by their shape, where a form prints a value with its label elsewhere (Egypt: the class numbers stand
   * alone on a line above the goods, and the label stands beside the middle of the goods). A line whose text,
   * written without spaces, matches `pattern` belongs to `field`, and the lines after it too; `when` names the
   * fields it may follow (so a bare number inside the goods is not taken for the class line).
   */
  lines?: Array<{ pattern: string; field: string; when?: string[] }>;
  /** forms read left to right: a label stands at the margin, and inside `field` the words left of `below_x` are the field `to` */
  label_x_max?: number;
  margin?: { field: string; below_x: number; to: string };
  /** tables: the columns from the left, each up to `to`; a row begins where the first column holds a number */
  columns?: Array<{ field: string; to: number }>;
  number_pattern?: string;
  /** written before a number that is not the office's own application number (an international registration) */
  number_prefix?: string;
}
export interface LabelsSpec { method: "labels"; prepare?: string; forms: FormSpec[]; accept?: string }

export interface Entry { form: string; page: number; page_to: number; fields: Record<string, string>; unplaced: string[] }

const AR = /[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]/;
const LATIN = /[A-Za-zÀ-ɏ]/;
const unescapeXml = (s: string) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, "&");

/** A word as it is read: Arabic turned round, with the numbers and Latin letters inside it left as they stand. */
export function logical(t: string): string {
  if (!AR.test(t)) return t;
  const r = [...t].reverse().join("");
  return r.replace(/[0-9A-Za-z]+(?:[./:@_-]+[0-9A-Za-z]+)*/g, (m) => [...m].reverse().join(""));
}

/** The words of each page with their place and height, from the output of `pdftotext -bbox`, as they are read. */
export function pagesOf(xml: string): LPage[] {
  const pages: LPage[] = [];
  const word = /<word xMin="([\d.-]+)" yMin="([\d.-]+)" xMax="([\d.-]+)" yMax="([\d.-]+)">([^<]*)<\/word>/g;
  for (const p of xml.split(/<page /).slice(1)) {
    const size = /^width="([\d.]+)" height="([\d.]+)"/.exec(p);
    const words: LWord[] = [];
    for (const m of p.matchAll(word)) {
      const t = logical(unescapeXml(m[5]!));
      if (t.trim()) words.push({ x: Number(m[1]), y: Number(m[2]), x2: Number(m[3]), h: Number(m[4]) - Number(m[2]), t });
    }
    pages.push({ width: size ? Number(size[1]) : 612, height: size ? Number(size[2]) : 792, words });
  }
  return pages;
}

/** Text without spaces or the stretching stroke, for telling a label however its letters were spaced on the page. */
export const tight = (s: string) => s.replace(/[\sـ‎‏]+/g, "");

interface FLine { x: number; x2: number; y: number; text: string; title?: boolean; words?: LWord[] }

/** Words at one height, as one text. With Arabic on the line it runs from the right, and Latin words keep their own order. */
function lineText(words: LWord[]): string {
  const rtl = words.some((w) => AR.test(w.t));
  const ws = [...words].sort((a, b) => (rtl ? b.x - a.x : a.x - b.x));
  // pieces that touch are one word (the file sometimes cuts a word in two, or sets a mark of punctuation apart)
  const parts: Array<{ t: string; latin: boolean; neutral: boolean; tail: number }> = [];
  let prev: LWord | null = null;
  for (const w of ws) {
    const gap = prev ? (rtl ? prev.x - w.x2 : w.x - prev.x2) : 99;
    const last = parts[parts.length - 1];
    const mixed = prev ? (AR.test(prev.t) && LATIN.test(w.t) && !AR.test(w.t)) || (AR.test(w.t) && LATIN.test(prev.t) && !AR.test(prev.t)) : true;
    // on a line that runs from the right, two pieces of a number or of a Latin word still stand left to right ("490" then "492" is 490492)
    const figures = (t: string) => /^[\d/\\.-]+$/.test(t);
    const ltr = (t: string) => !AR.test(t) && (/[0-9A-Za-z]/.test(t) || figures(t));
    const together = prev !== null && gap > -2 && (gap < 1 ? !mixed : rtl && gap < 2.6 && figures(prev.t) && figures(w.t));
    if (last && together) {
      if (rtl && ltr(w.t) && last.tail > 0) { const at = last.t.length - last.tail; last.t = last.t.slice(0, at) + w.t + last.t.slice(at); last.tail += w.t.length; }
      else { last.t += w.t; last.tail = ltr(w.t) ? w.t.length : 0; }
      last.latin = LATIN.test(last.t) && !AR.test(last.t); last.neutral = !LATIN.test(last.t) && !AR.test(last.t);
    }
    else parts.push({ t: w.t, latin: LATIN.test(w.t) && !AR.test(w.t), neutral: !LATIN.test(w.t) && !AR.test(w.t), tail: ltr(w.t) ? w.t.length : 0 });
    prev = w;
  }
  if (rtl) {
    // a run of Latin words stands left to right inside a line that runs from the right
    for (let i = 0; i < parts.length; i++) {
      if (!parts[i]!.latin) continue;
      let j = i;
      for (let k = i + 1; k < parts.length && (parts[k]!.latin || parts[k]!.neutral); k++) if (parts[k]!.latin) j = k;
      if (j > i) { const run = parts.slice(i, j + 1).reverse(); parts.splice(i, run.length, ...run); }
      i = j;
    }
  }
  return parts.map((p) => p.t).join(" ");
}

/** Words into lines, top to bottom: words within `tolerance` points of a line's first word are on it. */
function linesFrom(words: LWord[], tolerance: number): FLine[] {
  const ws = [...words].sort((a, b) => a.y - b.y);
  const out: FLine[] = [];
  let cur: LWord[] = [];
  const flush = () => {
    if (!cur.length) return;
    out.push({ x: Math.min(...cur.map((w) => w.x)), x2: Math.max(...cur.map((w) => w.x2)), y: cur[0]!.y, text: lineText(cur), words: cur });
    cur = [];
  };
  for (const w of ws) {
    if (cur.length && w.y - cur[0]!.y > tolerance) flush();
    cur.push(w);
  }
  flush();
  return out;
}

/**
 * The lines of a form page in the order they are read. A two-column form is read down its right column, then down
 * its left one; above the `break` line the columns part at `split.upper`, under it at `split.lower`. `upper` says
 * whether the notice being read is still above its break when the page begins; the answer for the next page is returned.
 */
export function flow(page: LPage, f: FormSpec, upper: boolean): { lines: FLine[]; upper: boolean } {
  const top = f.top ?? 0; const bottom = f.bottom ?? page.height;
  const body = page.words.filter((w) => w.y >= top && w.y < bottom);
  if (f.layout !== "columns" || !f.split) return { lines: linesFrom(body, 5), upper };
  const out: FLine[] = [];
  const big = f.title_height ? body.filter((w) => w.h > f.title_height!) : [];
  const rest = big.length ? body.filter((w) => !(w.h > f.title_height!)) : body;
  // each title on the page opens a notice; what stands between two titles is read with the first
  const titles = linesFrom(big, 8).map((l) => ({ ...l, title: true }));
  const bands = titles.length ? titles.map((t, i) => ({ title: t as FLine | null, from: t.y, to: titles[i + 1]?.y ?? Infinity })) : [];
  if (!titles.length || rest.some((w) => w.y < titles[0]!.y)) bands.unshift({ title: null, from: -Infinity, to: titles[0]?.y ?? Infinity });
  const wanted = f.break ? tight(f.break) : null;
  for (const band of bands) {
    const words = rest.filter((w) => w.y >= band.from && w.y < band.to);
    if (band.title) { out.push(band.title); upper = true; }
    // the break line: it stands alone on its row of the right column
    let breakY: number | null = null;
    if (wanted) {
      for (const l of linesFrom(words.filter((w) => w.x2 > f.split!.lower + 1.5), 5)) if (tight(l.text) === wanted) { breakY = l.y; break; }
    }
    const section = (ws: LWord[], split: number) => {
      const left = ws.filter((w) => w.x2 <= split + 1.5); const right = ws.filter((w) => w.x2 > split + 1.5);
      out.push(...linesFrom(right, 5), ...linesFrom(left, 5));
    };
    if (breakY !== null) {
      section(words.filter((w) => w.y < breakY! - 3), upper ? f.split.upper : f.split.lower);
      out.push({ x: 0, x2: 0, y: breakY, text: f.break! });
      section(words.filter((w) => w.y > breakY! + 3), f.split.lower);
      upper = false;
    } else section(words, upper ? f.split.upper : f.split.lower);
  }
  return { lines: out, upper };
}

/** Reads the notices of one form from pages given one after another. */
export class FormReader {
  private e: Entry | null = null;
  private field: string | null = null;
  private upper = true;
  private readonly f: FormSpec;
  private readonly labels: Array<{ key: string; def: LabelDef }>;
  private readonly start: string | null;
  private readonly end: string | null;
  private readonly brk: string | null;
  private readonly skip: string[];
  private readonly shapes: Array<{ re: RegExp; field: string; when?: string[] }>;

  constructor(f: FormSpec) {
    this.f = f;
    this.shapes = (f.lines ?? []).flatMap((x) => { try { return [{ re: new RegExp(x.pattern, "u"), field: x.field, when: x.when }]; } catch { return []; } });
    this.skip = (f.skip ?? []).map(tight).filter(Boolean);
    // the longest label first, so "Holder's Name:" is not taken for a shorter label that begins the same way
    this.labels = (f.labels ?? []).map((def) => ({ key: tight(def.label), def })).sort((a, b) => b.key.length - a.key.length);
    this.start = f.start ? tight(f.start) : null;
    this.end = f.end ? tight(f.end) : null;
    this.brk = f.break ? tight(f.break) : null;
  }

  /** the part of `text` that follows its first `n` letters (spaces not counted) */
  private static after(text: string, n: number): string {
    let seen = 0; let i = 0;
    for (; i < text.length && seen < n; i++) if (tight(text[i]!) !== "") seen += 1;
    return text.slice(i).replace(/^[\s:]+/, "").trim();
  }

  private put(field: string, text: string) {
    if (!this.e || !text) return;
    this.e.fields[field] = this.e.fields[field] ? `${this.e.fields[field]} ${text}` : text;
  }

  /**
   * A page of a "centred" form. Between the entry's heading and the next one, each label takes the lines that
   * stand as far above it as below it (the first value begins right under the heading). On a page that only
   * continues an entry, the lines above the first label continue the value being read, and the labels are worked
   * out from the foot of the page upwards.
   */
  private feedCentred(page: LPage, pageNo: number): Entry[] {
    const done: Entry[] = [];
    const f = this.f;
    // a colon printed a little lower than its label comes out as a line of its own, or at the head of a value line
    const lines = flow(page, f, true).lines.filter((l) => tight(l.text).replace(/^:+$/, "") !== "");
    const TOL = 4;
    const bare = (key: string) => key.replace(/:+$/, "");
    const labelOf = (t: string) => this.labels.find((x) => !x.def.inline && t.startsWith(bare(x.key)));
    let i = 0;
    const give = (field: string, text: string, first: boolean) => {
      if (!this.e || !text) return;
      const shape = first ? this.shapes.find((x) => x.re.test(tight(text)) && (!x.when || x.when.includes(field))) : undefined;
      const to = shape ? shape.field : field;
      if (!(to in this.e.fields)) this.e.fields[to] = "";
      this.put(to, text);
    };
    while (i < lines.length) {
      const t = tight(lines[i]!.text);
      if (this.start && (f.start_exact ? t === this.start : t.startsWith(this.start))) {
        if (this.e) done.push(this.e);
        this.e = { form: f.key, page: pageNo, page_to: pageNo, fields: { title: lines[i]!.text.trim() }, unplaced: [] };
        this.field = null;
        i += 1;
      }
      if (!this.e) { i += 1; continue; }
      // this entry's lines on this page: up to the next heading
      let end = i;
      while (end < lines.length && !(this.start && (f.start_exact ? tight(lines[end]!.text) === this.start : tight(lines[end]!.text).startsWith(this.start)))) end += 1;
      if (end > i) this.e.page_to = pageNo;
      const seg = lines.slice(i, end);
      const anchors = seg.map((l, k) => ({ k, hit: labelOf(tight(l.text)) })).filter((a) => a.hit);
      // which label each line belongs to (-1: none yet)
      const owner: number[] = seg.map(() => -1);
      if (this.field === null) {
        // from the heading down: a value begins where the one before it ended
        let from = 0;
        anchors.forEach((a, n) => {
          const next = anchors[n + 1]?.k ?? seg.length;
          if (a.hit!.def.top) {
            // what stands above it is the end of the value before it; what follows, up to the next label, is its own
            for (let k = from; k < a.k; k++) owner[k] = n - 1;
            for (let k = a.k; k < next; k++) owner[k] = n;
            from = next;
            return;
          }
          const top = seg[Math.min(from, a.k)]!.y; const y = seg[a.k]!.y;
          const bottom = 2 * y - top + TOL;
          let to = a.k;
          while (to + 1 < next && seg[to + 1]!.y <= bottom) to += 1;
          // the last label of the page keeps what is left under it (a value that runs on to the next page)
          if (n === anchors.length - 1) to = seg.length - 1;
          for (let k = Math.min(from, a.k); k <= to; k++) owner[k] = n;
          from = to + 1;
        });
        // a value too long to be centred on its label (it fills the page) leaves its lines to the label after it:
        // from the last label up, what stands further above a label than its value reaches below it goes back
        for (let n = anchors.length - 1; n >= 1; n--) {
          const mine = owner.map((o, k) => (o === n ? k : -1)).filter((k) => k >= 0);
          if (!mine.length || anchors[n]!.hit!.def.top) continue;
          const y = seg[anchors[n]!.k]!.y; const bottom = seg[mine[mine.length - 1]!]!.y;
          // a line's height of slack: a label is not always set exactly beside the middle
          const top = 2 * y - bottom - 18;
          for (const k of mine) if (k < anchors[n]!.k && seg[k]!.y < top) owner[k] = n - 1;
        }
      } else {
        // a page that continues: from the foot up; what stands above the first value continues the one being read
        let until = seg.length - 1;
        for (let n = anchors.length - 1; n >= 0; n--) {
          const a = anchors[n]!; const prev = anchors[n - 1]?.k ?? -1;
          const y = seg[a.k]!.y; const bottom = seg[Math.max(until, a.k)]!.y;
          const top = 2 * y - bottom - TOL;
          let fromK = a.k;
          while (!a.hit!.def.top && fromK - 1 > prev && seg[fromK - 1]!.y >= top) fromK -= 1;
          for (let k = fromK; k <= Math.max(until, a.k); k++) owner[k] = n;
          until = fromK - 1;
        }
      }
      let firstOf = -1;
      seg.forEach((l, k) => {
        const text = l.text.trim().replace(/^:\s*/, "");
        const n = owner[k]!;
        if (n < 0) {
          if (this.field === null) this.e!.unplaced.push(text); else this.put(this.field, text);
          return;
        }
        const a = anchors[n]!; const field = a.hit!.def.field;
        const first = firstOf !== n; firstOf = n;
        if (k === a.k) give(field, FormReader.after(text, bare(a.hit!.key).length), first); else give(field, text, first);
        if (!(field in this.e!.fields)) this.e!.fields[field] = "";
      });
      if (anchors.length) this.field = anchors[anchors.length - 1]!.hit!.def.field;
      i = end;
    }
    return done;
  }

  feed(page: LPage, pageNo: number): Entry[] {
    if (this.f.layout === "centred") return this.feedCentred(page, pageNo);
    const done: Entry[] = [];
    const f = this.f;
    const fl = flow(page, f, this.upper);
    this.upper = fl.upper;
    for (const l of fl.lines) {
      const text = l.text.trim();
      if (!text) continue;
      const t = tight(text);
      if (this.start && (f.start_exact ? t === this.start : l.title ? t.startsWith(this.start) : !f.title_height && t.startsWith(this.start))) {
        if (this.e) done.push(this.e);
        this.e = { form: f.key, page: pageNo, page_to: pageNo, fields: { title: text }, unplaced: [] };
        this.field = null;
        continue;
      }
      if (!this.e) continue;
      this.e.page_to = pageNo;
      if (this.brk && t === this.brk) { this.field = null; continue; }
      if (this.skip.some((x) => t.startsWith(x))) continue;
      if (this.end && t.startsWith(this.end)) { this.field = "_closing"; continue; }
      const atMargin = f.label_x_max === undefined || l.x <= f.label_x_max;
      const hit = atMargin ? this.labels.find((x) => !x.def.inline && t.startsWith(x.key)) : undefined;
      if (hit) {
        let rest = FormReader.after(text, hit.key.length);
        this.field = hit.def.field;
        if (!(this.field in this.e.fields)) this.e.fields[this.field] = "";
        // a second label on the same line ("… بتاريخ : 2022/03/16", "… Date: 2025/05/22")
        for (const x of this.labels.filter((y) => y.def.inline === hit.def.field)) {
          const at = FormReader.find(rest, x.key);
          if (at === null) continue;
          const value = FormReader.after(rest.slice(at.from), x.key.length);
          rest = rest.slice(0, at.from).trim();
          if (!(x.def.field in this.e.fields)) this.e.fields[x.def.field] = "";
          this.put(x.def.field, value);
          if (value === "") this.field = x.def.field;
        }
        this.put(hit.def.field, rest);
        if (f.then?.[hit.def.field]) this.field = f.then[hit.def.field]!;
        continue;
      }
      const shape = this.shapes.find((x) => x.re.test(t) && (!x.when || x.when.includes(this.field ?? "")));
      if (shape) {
        this.field = shape.field;
        if (!(this.field in this.e.fields)) this.e.fields[this.field] = "";
        this.put(this.field, text);
        continue;
      }
      // inside one field, what stands at the margin is another (the classes beside the goods)
      if (f.margin && this.field === f.margin.field && l.words) {
        const left = l.words.filter((w) => w.x < f.margin!.below_x); const right = l.words.filter((w) => w.x >= f.margin!.below_x);
        if (left.length) this.put(f.margin.to, lineText(left));
        if (right.length) this.put(this.field, lineText(right));
        continue;
      }
      if (this.field === "_closing") continue;
      if (this.field === null) { this.e.unplaced.push(text); continue; }
      this.put(this.field, text);
    }
    return done;
  }

  /** where a label written without spaces begins in a text written with them */
  private static find(text: string, key: string): { from: number } | null {
    for (let i = 0; i < text.length; i++) {
      if (tight(text[i]!) === "" || (i > 0 && tight(text[i - 1]!) !== "")) continue;
      if (tight(text.slice(i)).startsWith(key)) return { from: i };
    }
    return null;
  }

  end_(): Entry[] {
    if (!this.e) return [];
    const e = this.e; this.e = null; this.field = null; this.upper = true;
    return [e];
  }
}

/** Reads the rows of a table from pages given one after another. A row begins where the first column holds a number. */
export class TableReader {
  private e: Entry | null = null;
  private readonly f: FormSpec;
  private readonly num: RegExp;

  constructor(f: FormSpec) {
    this.f = f;
    let n: RegExp;
    try { n = new RegExp(`^(?:${f.number_pattern ?? "\\d{4,8}"})$`); } catch { n = /^\d{4,8}$/; }
    this.num = n;
  }

  feed(page: LPage, pageNo: number): Entry[] {
    const done: Entry[] = [];
    const cols = this.f.columns ?? [];
    const first = cols[0];
    if (!first) return done;
    const top = this.f.top ?? 0; const bottom = this.f.bottom ?? page.height;
    const col = (w: LWord) => { const i = cols.findIndex((c) => w.x < c.to); return i < 0 ? cols.length - 1 : i; };
    const body = page.words.filter((w) => w.y >= top && w.y < bottom).sort((a, b) => a.y - b.y);
    let row: LWord[] = [];
    const flush = () => {
      if (!row.length) return;
      const cells = cols.map((_, i) => row.filter((w) => col(w) === i));
      const key = cells[0]!.map((w) => w.t).join("");
      if (this.num.test(key)) {
        if (this.e) done.push(this.e);
        this.e = { form: this.f.key, page: pageNo, page_to: pageNo, fields: {}, unplaced: [] };
      }
      if (this.e) {
        this.e.page_to = pageNo;
        cells.forEach((c, i) => {
          if (!c.length) return;
          const name = cols[i]!.field; const text = lineText(c);
          this.e!.fields[name] = this.e!.fields[name] ? `${this.e!.fields[name]} ${text}` : text;
        });
      }
      row = [];
    };
    for (const w of body) {
      if (row.length && w.y - row[0]!.y > 4) flush();
      row.push(w);
    }
    flush();
    return done;
  }

  end_(): Entry[] {
    if (!this.e) return [];
    const e = this.e; this.e = null;
    return [e];
  }
}

/** The forms of a source with what they take from one another (`like`) filled in. */
export function formsOf(spec: LabelsSpec): FormSpec[] {
  const all = Array.isArray(spec.forms) ? spec.forms : [];
  return all.map((f) => {
    const base = f.like ? all.find((x) => x.key === f.like) : undefined;
    return base ? { ...base, ...f } : f;
  });
}

/** Which form a file holds: the first whose title pattern matches the opening text of the file's first page. */
export function formOf(firstPage: LPage, forms: FormSpec[]): FormSpec | null {
  const open = tight(linesFrom(firstPage.words.filter((w) => w.y < firstPage.height * 0.35), 6).map((l) => l.text).join("\n"));
  for (const f of forms) {
    try { if (new RegExp(f.title, "u").test(open)) return f; } catch { /* a pattern that cannot be read matches nothing */ }
  }
  return null;
}

const isoDate = (s: string): string | null => {
  const a = /(\d{4})[/.\\-](\d{1,2})[/.\\-](\d{1,2})/.exec(s);
  if (a) return `${a[1]}-${a[2]!.padStart(2, "0")}-${a[3]!.padStart(2, "0")}`;
  const b = /(\d{1,2})[/.\\-](\d{1,2})[/.\\-](\d{4})/.exec(s);
  return b ? `${b[3]}-${b[2]!.padStart(2, "0")}-${b[1]!.padStart(2, "0")}` : null;
};
const realDate = (iso: string | null) => {
  if (!iso) return false;
  const [y, m, d] = iso.split("-").map(Number) as [number, number, number];
  return y >= 1900 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31;
};

export interface LabelsMark {
  page: number; page_to: number; printed_page: null; file: string; part: string;
  application_no: string | null; filing_date: string | null;
  mark_text_ar: string | null; mark_text_en: string | null; mark_type: null; has_image: null;
  classes: number[]; goods: string | null;
  applicant_name: string | null; applicant_country: string | null; applicant_address: string | null;
  agent_name: string | null; agent_city: null;
  international_no: string | null; other: Record<string, string>;
  confidence: number; notes: string | null; read_by: "labels";
}

const clean = (s: string | undefined) => (s ?? "").replace(/\s+/g, " ").replace(/^[\s,،:]+|[\s,،]+$/g, "").trim();

/** A notice that publishes an application, as the mark the watch compares. */
export function markOf(e: Entry, f: FormSpec, file: string): LabelsMark {
  const v = e.fields;
  const numberRaw = clean(v.number);
  const no = /[0-9][0-9A-Za-z/.-]*/.exec(numberRaw)?.[0] ?? null;
  const filed = isoDate(v.filed ?? "");
  const wording = clean(v.mark);
  const words = wording ? wording.split(" ") : [];
  const ar = words.filter((w) => AR.test(w)).join(" ");
  const en = words.filter((w) => !AR.test(w)).join(" ");
  const classes = [...new Set(clean(v.classes).split(/[^\d]+/).filter(Boolean).map(Number).filter((n) => n >= 1 && n <= 45))].sort((a, b) => a - b);
  const country = /\(([A-Z]{2})\)\s*$/.exec(clean(v.address))?.[1] ?? null;
  const known = new Set(["title", "number", "filed", "mark", "classes", "goods", "applicant", "address", "agent"]);
  const other: Record<string, string> = {};
  for (const [k, val] of Object.entries(v)) if (!known.has(k) && !k.startsWith("_") && clean(val)) other[k] = clean(val).slice(0, 4000);
  if (e.unplaced.length) other.unplaced = e.unplaced.join(" ").slice(0, 2000);
  const missing: string[] = [];
  if (!no) missing.push("number");
  if (!clean(v.applicant)) missing.push("applicant");
  if (classes.length === 0) missing.push("classes");
  if (!clean(v.goods)) missing.push("goods");
  if (clean(v.filed) ? !realDate(filed) : true) missing.push("date");
  if (!("mark" in v) && f.labels?.some((l) => l.field === "mark")) missing.push("wording");
  const notes = [missing.length ? `not found in the notice: ${missing.join(", ")}` : null, other.unplaced ? "text that belongs to no field was found in the notice" : null].filter(Boolean).join("; ");
  return {
    page: e.page, page_to: e.page_to, printed_page: null, file, part: f.key,
    application_no: no ? `${f.number_prefix ?? ""}${no}` : null, filing_date: realDate(filed) ? filed : null,
    mark_text_ar: ar ? ar.slice(0, 300) : null, mark_text_en: en ? en.slice(0, 300) : null, mark_type: null, has_image: null,
    classes, goods: clean(v.goods) || null,
    applicant_name: clean(v.applicant) || null, applicant_country: country, applicant_address: clean(v.address) || null,
    agent_name: clean(v.agent) || null, agent_city: null,
    international_no: f.number_prefix && no ? no : null, other,
    confidence: missing.length || other.unplaced ? 0.5 : 1, notes: notes || null, read_by: "labels",
  };
}

export interface LabelsNotice { part: string; file: string; page: number; page_to: number; application_no: string | null; fields: Record<string, string>; complete: boolean }

/** Any other notice or table row (a change, a transfer, a registration, a renewal): kept as read, with its number. */
export function noticeOf(e: Entry, f: FormSpec, file: string): LabelsNotice {
  const fields: Record<string, string> = {};
  for (const [k, val] of Object.entries(e.fields)) if (k !== "title" && !k.startsWith("_") && clean(val)) fields[k] = clean(val).slice(0, 8000);
  if (e.unplaced.length) fields.unplaced = e.unplaced.join(" ").slice(0, 2000);
  const no = /[0-9][0-9A-Za-z/.-]*/.exec(fields.number ?? "")?.[0] ?? null;
  return { part: f.key, file, page: e.page, page_to: e.page_to, application_no: no, fields, complete: no !== null && !fields.unplaced };
}
