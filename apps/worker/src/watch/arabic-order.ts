import { open, stat } from "node:fs/promises";

const ARABIC_BLOCKS = new Set(["06", "07", "08", "FB", "FC", "FD", "FE"]);

/**
 * Arabic in the order it is read. A PDF made by a word processor draws the joined letters lam-alef ("لا") as one
 * shape and says that the shape stands for the two letters, first the lam, then the alef. pdftotext gives the
 * letters of a word in the order the shapes stand on the page (left to right), so after a word is turned round those
 * two letters come out the wrong way ("العالمة" for "العلامة"), and nothing in the text tells such a pair from an
 * alef followed by a lam. Here, in a copy of the file with its tables of letters laid open (qpdf --qdf), in each
 * table a shape that stands for several Arabic letters has those letters written in the opposite order; turning the
 * word round then puts them right. The length of the file does not change, so nothing else in it is touched.
 * The copy is only read for its text; the pages shown to a reviewer are cut from the office's own file.
 */
export async function arabicOrderInPlace(out: string): Promise<number> {
  const size = (await stat(out)).size;
  const fh = await open(out, "r+");
  let changed = 0;
  try {
    const BLOCK = 8 * 1024 * 1024; const OVER = 256 * 1024;
    const begin = Buffer.from("beginbf"); const endTag = Buffer.from("endbf");
    for (let at = 0; at < size; at += BLOCK) {
      const len = Math.min(size - at, BLOCK + OVER);
      const buf = Buffer.alloc(len);
      await fh.read(buf, 0, len, at);
      let dirty = false;
      for (let i = buf.indexOf(begin); i >= 0 && i < BLOCK; i = buf.indexOf(begin, i + 1)) {
        const e = buf.indexOf(endTag, i);
        if (e < 0) continue;                              // a table that runs past what was read is met again in the next block
        for (let a = buf.indexOf(0x3c, i); a >= 0 && a < e; a = buf.indexOf(0x3c, a + 1)) {
          const b = buf.indexOf(0x3e, a);
          if (b < 0 || b > e) break;
          const hex = buf.toString("latin1", a + 1, b);
          if (hex.length <= 4 || hex.length % 4 !== 0 || !/^[0-9A-Fa-f]+$/.test(hex)) { a = b; continue; }
          const units = hex.match(/.{4}/g)!;
          if (!units.every((u) => ARABIC_BLOCKS.has(u.slice(0, 2).toUpperCase()))) { a = b; continue; }
          buf.write(units.reverse().join(""), a + 1, "latin1");
          dirty = true; changed += 1; a = b;
        }
        i = e;
      }
      if (dirty) await fh.write(buf, 0, len, at);
    }
  } finally { await fh.close(); }
  return changed;
}
