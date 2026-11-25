import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";

export const runtime = "nodejs";
export const maxDuration = 120;

const MAX = 8 * 1024 * 1024;
const KINDS = new Set(["image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp"]);

/**
 * Operations Console → Pictures → "Compare two pictures" (Founder, 25 Nov 2026: a real case to try). Staff give two
 * pictures; each is sent to the picture service inside the private network (EMBEDDINGS_URL), and the closeness of
 * the two by each model comes back to the page. The pictures are not kept anywhere: they are read, sent, and
 * forgotten; only the figures travel back in the page's address. Nothing is matched and no alert is raised.
 */
export async function POST(req: Request) {
  const session = await getSession();
  const from = /\/(ar|en)\//.exec(req.headers.get("referer") ?? "")?.[1] ?? "en";
  if (Number(req.headers.get("content-length") ?? 0) > 2 * MAX + 1024 * 1024) {
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
  const back = (params: Record<string, string>) => go(req, `/${locale}/ops/pictures`, params, "compare");
  const base = (process.env.EMBEDDINGS_URL ?? "").trim().replace(/\/+$/, "");
  if (!/^https?:\/\/[^\s/]+/.test(base)) return back({ error: "pictureServiceOff" });
  const files = [form.get("a"), form.get("b")];
  if (!files.every((f): f is File => f instanceof File && f.size > 0)) return back({ error: "pictureMissing" });
  if (files.some((f) => f.size > MAX)) return back({ error: "pictureTooLarge" });
  if (files.some((f) => !KINDS.has(f.type))) return back({ error: "pictureKind" });
  try {
    const health = (await (await fetch(`${base}/health`, { signal: AbortSignal.timeout(15_000) })).json()) as { models_loaded?: boolean; models?: string[] };
    if (!health.models_loaded) return back({ error: "pictureServiceOff" });
    const payloads = await Promise.all(files.map(async (f) => Buffer.from(await f.arrayBuffer()).toString("base64")));
    const out: Record<string, string> = { cmp: "1" };
    const hashes: Array<string | null> = [];
    for (const model of ["siglip2", "dinov3"]) {
      if (!(health.models ?? []).includes(model)) continue;
      const vectors: number[][] = [];
      for (const payload of payloads) {
        const res = await fetch(`${base}/embed`, { method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(60_000), body: JSON.stringify({ kind: "image", model, payload }) });
        if (res.status === 422) return back({ error: "pictureKind" });
        if (!res.ok) throw new Error(`the picture service answered ${res.status}`);
        const r = (await res.json()) as { vector: number[]; phash: string | null };
        vectors.push(r.vector);
        if (model === "siglip2") hashes.push(r.phash);
      }
      const dot = vectors[0]!.reduce((sum, x, i) => sum + x * (vectors[1]![i] ?? 0), 0);
      out[model === "siglip2" ? "s" : "d"] = (Math.round(dot * 1000) / 10).toFixed(1);
    }
    if (hashes.length === 2 && hashes[0] && hashes[0] === hashes[1]) out.same = "1";
    return back(out);
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "ops.pictures.compare", message: (e as Error).message.slice(0, 300) }));
    return back({ error: "pictureServiceOff" });
  }
}
