/** Which image of a page is a mark's picture (see mark-pictures.ts). Pure: a listing in, the choice out. */
export interface PictureRule { min?: number; not?: Array<[number, number]> }

/** per page, the number (within this listing) and size of the image that is the mark's picture */
export function picturesIn(listing: string, rule: PictureRule): Map<number, { num: number; w: number; h: number }> {
  const min = rule.min ?? 24;
  const not = new Set((rule.not ?? []).map(([w, h]) => `${w}x${h}`));
  const best = new Map<number, { num: number; w: number; h: number }>();
  for (const line of listing.split("\n").slice(2)) {
    const c = line.trim().split(/\s+/);
    if (c.length < 5 || c[2] !== "image") continue;
    const page = Number(c[0]); const num = Number(c[1]); const w = Number(c[3]); const h = Number(c[4]);
    if (!Number.isFinite(page) || !Number.isFinite(num) || w < min || h < min || not.has(`${w}x${h}`)) continue;
    const b = best.get(page);
    if (!b || w * h > b.w * b.h) best.set(page, { num, w, h });
  }
  return best;
}
