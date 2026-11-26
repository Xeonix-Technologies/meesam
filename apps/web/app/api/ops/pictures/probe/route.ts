import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { probeIssueLevel, probeIssueLevelKind, probeIssuePictures, probeIssueSpread, type PictureProbe } from "@/lib/ops";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";

export const runtime = "nodejs";
export const maxDuration = 120;

const MAX = 8 * 1024 * 1024;
const KINDS = new Set(["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp"]);
/** The marks a picture of a given kind is measured against: its own kind; the two combined kinds together. */
const GROUP: Record<string, string[]> = { word: ["word"], device: ["device"], word_device: ["word_device", "device_word"], device_word: ["word_device", "device_word"] };
const STEPS = [90, 80, 70, 60, 50, 40, 30, 20, 10, 0, -10];

/**
 * Operations Console → Pictures → one issue → "One picture against this issue" (25 Nov 2026). The question the
 * watch will really ask: a mark that is not in the bulletin (a customer's mark) against every picture of it. Staff
 * give one picture; the picture service (private network, EMBEDDINGS_URL) returns its two fingerprints; the
 * database returns the nearest pictures of the issue by each model and how many stand at each step of closeness.
 * The picture and its fingerprints are not kept: only the marks' ids and the figures travel back in the address.
 * Nothing is matched and no alert is raised.
 */
export async function POST(req: Request) {
  const session = await getSession();
  const from = /\/(ar|en)\//.exec(req.headers.get("referer") ?? "")?.[1] ?? "en";
  if (Number(req.headers.get("content-length") ?? 0) > MAX + 1024 * 1024) {
    await req.body?.cancel().catch(() => undefined);
    return go(req, `/${from}/ops/pictures`, { error: "pictureTooLarge" }, "compare");
  }
  let form: FormData;
  try { form = await req.formData(); } catch { return new NextResponse(null, { status: 400 }); }
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  if (!session) return go(req, `/${locale}/login`);
  const roles = await staffRoles(session);
  if (!roles.includes("watch_lead") && !roles.includes("publication_reviewer")) return new NextResponse(null, { status: 404 });
  const issue = String(form.get("issue") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(issue)) return new NextResponse(null, { status: 400 });
  const back = (params: Record<string, string>) => go(req, `/${locale}/ops/pictures/${issue}`, params, "probe");
  const base = (process.env.EMBEDDINGS_URL ?? "").trim().replace(/\/+$/, "");
  if (!/^https?:\/\/[^\s/]+/.test(base)) return back({ error: "pictureServiceOff" });
  const file = form.get("picture");
  if (!(file instanceof File) || file.size === 0) return back({ error: "pictureMissing" });
  if (file.size > MAX) return back({ error: "pictureTooLarge" });
  if (!KINDS.has(file.type)) return back({ error: "pictureKind" });
  try {
    const health = (await (await fetch(`${base}/health`, { signal: AbortSignal.timeout(15_000) })).json()) as { models_loaded?: boolean; models?: string[] };
    if (!health.models_loaded) return back({ error: "pictureServiceOff" });
    const payload = Buffer.from(await file.arrayBuffer()).toString("base64");
    const probe: PictureProbe = { siglip: null, siglipEngine: null, dino: null, dinoEngine: null };
    for (const model of ["siglip2", "dinov3"] as const) {
      if (!(health.models ?? []).includes(model)) continue;
      const res = await fetch(`${base}/embed`, { method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(60_000), body: JSON.stringify({ kind: "image", model, payload }) });
      if (res.status === 422) return back({ error: "pictureKind" });
      if (!res.ok) throw new Error(`the picture service answered ${res.status}`);
      const r = (await res.json()) as { vector: number[]; engine: string };
      if (!Array.isArray(r.vector) || r.vector.length !== 768 || !r.vector.every((x) => Number.isFinite(x))) throw new Error("the picture service returned no usable fingerprint");
      const text = `[${r.vector.join(",")}]`;
      if (model === "siglip2") { probe.siglip = text; probe.siglipEngine = r.engine; } else { probe.dino = text; probe.dinoEngine = r.engine; }
    }
    const [near, spread, level] = await Promise.all([probeIssuePictures(issue, probe, 10), probeIssueSpread(issue, probe), probeIssueLevel(issue, probe)]);
    const lv = (model: string) => { const x = level.find((y) => y.model === model); return x ? `${x.level}_${x.spread}_${x.pictures}` : ""; };
    const kind = String(form.get("kind") ?? "");
    const own = GROUP[kind] ? await probeIssueLevelKind(issue, probe, GROUP[kind]!) : [];
    const lk = (model: string) => { const x = own.find((y) => y.model === model); return x ? `${x.level}_${x.spread}_${x.pictures}` : ""; };
    const n = (v: number | null) => (v === null ? "" : String(v));
    const counts = (model: string) => STEPS.map((st) => spread.find((x) => x.model === model && x.step === st)?.marks ?? 0).join(".");
    return back({ pr: near.map((x) => [x.id, n(x.siglip), n(x.dino), n(x.rank_siglip), n(x.rank_dino)].join("_")).join(","), ps: counts("siglip2"), pd: counts("dinov3"), ls: lv("siglip2"), ld: lv("dinov3"), ...(GROUP[kind] ? { pk: kind, ks: lk("siglip2"), kd: lk("dinov3") } : {}) });
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "ops.pictures.probe", message: (e as Error).message.slice(0, 300) }));
    return back({ error: "pictureServiceOff" });
  }
}
