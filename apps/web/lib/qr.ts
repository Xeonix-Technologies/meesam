/**
 * A QR code drawn by Meesam itself (Founder ruling 23 Nov 2026: the authenticator set-up shows a code to scan).
 * The set-up key must never leave Meesam, so no outside service or library draws it: this module turns a short
 * text into the grid of dark and light squares (ISO/IEC 18004, byte mode, error correction level M, versions 1–12,
 * which hold up to 287 bytes; an authenticator link is about 130).
 */

/** per version: [error-correction codewords per block, blocks in group 1, data codewords in each, blocks in group 2] (group 2 holds one more each) */
const BLOCKS: Array<[number, number, number, number]> = [
  [10, 1, 16, 0], [16, 1, 28, 0], [26, 1, 44, 0], [18, 2, 32, 0], [24, 2, 43, 0], [16, 4, 27, 0],
  [18, 4, 31, 0], [22, 2, 38, 2], [22, 3, 36, 2], [26, 4, 43, 1], [30, 1, 50, 4], [22, 6, 36, 2],
];
const ALIGN: number[][] = [[], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50], [6, 30, 54], [6, 32, 58]];

// arithmetic in GF(256), polynomial x^8 + x^4 + x^3 + x^2 + 1
const EXP = new Uint8Array(512), LOG = new Uint8Array(256);
for (let i = 0, x = 1; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11d; }
for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255]!;
const mul = (a: number, b: number) => (a === 0 || b === 0 ? 0 : EXP[LOG[a]! + LOG[b]!]!);

function errorCodewords(data: number[], n: number): number[] {
  // generator polynomial (x - 2^0)(x - 2^1)…(x - 2^(n-1)), highest power first, leading 1 left out
  const gen = new Array<number>(n).fill(0); gen[n - 1] = 1;
  for (let i = 0, root = 1; i < n; i++, root = mul(root, 2)) {
    for (let j = 0; j < n; j++) { gen[j] = mul(gen[j]!, root); if (j + 1 < n) gen[j]! ^= gen[j + 1]!; }
  }
  const rem = new Array<number>(n).fill(0);
  for (const b of data) {
    const f = b ^ rem.shift()!; rem.push(0);
    for (let j = 0; j < n; j++) rem[j]! ^= mul(gen[j]!, f);
  }
  return rem;
}

const dataCapacity = (v: number) => { const [, g1, d, g2] = BLOCKS[v - 1]!; return g1 * d + g2 * (d + 1); };

/** The grid for a text: `size` squares a side, `dark[y][x]`. Throws when the text is too long for version 12. */
export function qrMatrix(text: string): { size: number; dark: boolean[][] } {
  const bytes = [...new TextEncoder().encode(text)];
  let version = 0;
  for (let v = 1; v <= BLOCKS.length; v++) {
    if (4 + (v < 10 ? 8 : 16) + bytes.length * 8 <= dataCapacity(v) * 8) { version = v; break; }
  }
  if (!version) throw new Error("the text is too long for a QR code");
  const [ecLen, g1, dLen, g2] = BLOCKS[version - 1]!;
  const capacity = dataCapacity(version);

  // the bit stream: mode, length, the bytes, a terminator, padding to the capacity
  const bits: number[] = [];
  const put = (value: number, len: number) => { for (let i = len - 1; i >= 0; i--) bits.push((value >>> i) & 1); };
  put(0b0100, 4); put(bytes.length, version < 10 ? 8 : 16);
  for (const b of bytes) put(b, 8);
  put(0, Math.min(4, capacity * 8 - bits.length));
  while (bits.length % 8) bits.push(0);
  const data: number[] = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));
  for (let pad = 0xec; data.length < capacity; pad ^= 0xec ^ 0x11) data.push(pad);

  // blocks, each with its error-correction codewords, then interleaved
  const blocks: Array<{ d: number[]; e: number[] }> = [];
  for (let b = 0, at = 0; b < g1 + g2; b++) {
    const len = dLen + (b >= g1 ? 1 : 0);
    const d = data.slice(at, at + len); at += len;
    blocks.push({ d, e: errorCodewords(d, ecLen) });
  }
  const stream: number[] = [];
  for (let i = 0; i <= dLen; i++) for (const b of blocks) if (i < b.d.length) stream.push(b.d[i]!);
  for (let i = 0; i < ecLen; i++) for (const b of blocks) stream.push(b.e[i]!);

  const size = version * 4 + 17;
  const dark = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const fixed = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const set = (x: number, y: number, on: boolean) => { if (x >= 0 && y >= 0 && x < size && y < size) { dark[y]![x] = on; fixed[y]![x] = true; } };

  // the three corner squares with their light border, the timing lines, the small alignment squares
  const finder = (cx: number, cy: number) => {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const d = Math.max(Math.abs(dx), Math.abs(dy));
      set(cx + dx, cy + dy, d !== 2 && d !== 4);
    }
  };
  for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
  finder(3, 3); finder(size - 4, 3); finder(3, size - 4);
  const al = ALIGN[version - 1]!;
  for (const ay of al) for (const ax of al) {
    if ((ax === 6 && ay === 6) || (ax === 6 && ay === size - 7) || (ax === size - 7 && ay === 6)) continue;
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }
  const format = (mask: number) => {
    const d = mask;                                   // level M is 00, then the three mask bits
    let rem = d;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    const f = ((d << 10) | rem) ^ 0x5412;
    const bit = (i: number) => ((f >>> i) & 1) === 1;
    for (let i = 0; i <= 5; i++) set(8, i, bit(i));
    set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8));
    for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i));
    set(8, size - 8, true);
  };
  format(0);                                          // reserves the places; the real value is written once the mask is chosen
  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const v = (version << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const on = ((v >>> i) & 1) === 1, a = size - 11 + (i % 3), b = Math.floor(i / 3);
      set(a, b, on); set(b, a, on);
    }
  }

  // the codewords, in the zigzag from the bottom right corner
  let n = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) for (let j = 0; j < 2; j++) {
      const x = right - j, up = ((right + 1) & 2) === 0, y = up ? size - 1 - vert : vert;
      if (!fixed[y]![x] && n < stream.length * 8) { dark[y]![x] = ((stream[n >>> 3]! >>> (7 - (n & 7))) & 1) === 1; n++; }
    }
  }

  // the mask that leaves the calmest pattern
  const masks: Array<(x: number, y: number) => boolean> = [
    (x, y) => (x + y) % 2 === 0, (_x, y) => y % 2 === 0, (x) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
    (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0, (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
  ];
  const apply = (m: number) => { for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fixed[y]![x] && masks[m]!(x, y)) dark[y]![x] = !dark[y]![x]; };
  const penalty = () => {
    let p = 0, total = 0;
    const line = (get: (i: number) => boolean) => {
      let run = 1;
      for (let i = 1; i <= size; i++) {
        if (i < size && get(i) === get(i - 1)) run++;
        else { if (run >= 5) p += run - 2; run = 1; }
      }
      for (let i = 0; i + 10 < size; i++) {
        const s = (k: number) => get(i + k);
        const core = (o: number) => s(o) && !s(o + 1) && s(o + 2) && s(o + 3) && s(o + 4) && !s(o + 5) && s(o + 6);
        if ((core(0) && !s(7) && !s(8) && !s(9) && !s(10)) || (!s(0) && !s(1) && !s(2) && !s(3) && core(4))) p += 40;
      }
    };
    for (let i = 0; i < size; i++) { line((k) => dark[i]![k]!); line((k) => dark[k]![i]!); }
    for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
      if (dark[y]![x]) total++;
      if (x + 1 < size && y + 1 < size && dark[y]![x] === dark[y]![x + 1] && dark[y]![x] === dark[y + 1]![x] && dark[y]![x] === dark[y + 1]![x + 1]) p += 3;
    }
    return p + Math.floor(Math.abs(total * 20 - size * size * 10) / (size * size)) * 10;
  };
  let best = 0, least = Infinity;
  for (let m = 0; m < 8; m++) { apply(m); format(m); const p = penalty(); if (p < least) { least = p; best = m; } apply(m); }
  apply(best); format(best);
  return { size, dark };
}

/** The grid as one SVG path (squares of one unit, a quiet border of four around it), for an inline <svg>. */
export function qrSvg(text: string): { box: number; path: string } {
  const { size, dark } = qrMatrix(text);
  const quiet = 4;
  let path = "";
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      if (!dark[y]![x]) continue;
      let w = 1; while (x + w < size && dark[y]![x + w]) w++;
      path += `M${x + quiet} ${y + quiet}h${w}v1h-${w}z`;
      x += w - 1;
    }
  }
  return { box: size + quiet * 2, path };
}
