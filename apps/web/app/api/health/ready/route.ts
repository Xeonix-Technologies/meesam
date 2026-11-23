import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * A fuller check than /api/health (which stays dependency-free for the rollout): can the web service read its
 * database, and are its link-type settings well formed? It names settings and gives an error code, never a value.
 */
const link = (name: string, need: RegExp): string => {
  const raw = (process.env[name] ?? "").trim();
  if (!raw) return "missing";
  try { return need.test(new URL(raw).protocol) ? "ok" : "not the expected kind of link"; } catch { return "not a valid link"; }
};

/** What is wrong with a malformed link, in words that show nothing of the value itself. */
const shape = (name: string): string[] => {
  const raw = process.env[name] ?? "";
  const out: string[] = [];
  if (raw !== raw.trim()) out.push("space or line break at an end");
  if (/\s/.test(raw.trim())) out.push("space or line break inside");
  if (/["'`]/.test(raw)) out.push("quotation mark");
  if (raw.includes("${{") || raw.includes("}}")) out.push("unresolved ${{reference}}");
  if (!/^postgres(ql)?:\/\//.test(raw.trim())) out.push("does not begin with postgresql://");
  const at = (raw.match(/@/g) ?? []).length;
  if (at !== 1) out.push(`${at} @ signs (one expected)`);
  const after = raw.slice(raw.lastIndexOf("@") + 1);
  if (at >= 1 && !/^[A-Za-z0-9.\-]+(:\d+)?\/[^\s/?#]+(\?.*)?$/.test(after.trim())) out.push("the part after @ is not host:port/database");
  if (at >= 1 && /[\/?#\[\]]/.test(raw.slice(raw.indexOf("://") + 3, raw.lastIndexOf("@")))) out.push("the user or password part holds one of / ? # [ ]");
  return out;
};

export async function GET() {
  const config = {
    APP_URL: link("APP_URL", /^https?:$/),
    DATABASE_POOL_URL: link(process.env.DATABASE_POOL_URL ? "DATABASE_POOL_URL" : "DATABASE_URL", /^postgres(ql)?:$/),
  };
  let database = "ok";
  try {
    await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT 1`));
  } catch (e) {
    const err = e as { code?: string; cause?: { code?: string }; name?: string; message?: string };
    const code = err.cause?.code ?? err.code ?? (err.message === "Invalid URL" ? "INVALID_URL" : err.name ?? "error");
    database = `failed (${String(code).slice(0, 40)})`;
    console.error(JSON.stringify({ level: "error", at: "health.ready", code }));
  }
  const poolName = process.env.DATABASE_POOL_URL ? "DATABASE_POOL_URL" : "DATABASE_URL";
  const hints = config.DATABASE_POOL_URL === "ok" ? undefined : shape(poolName);
  const ok = database === "ok" && Object.values(config).every((v) => v === "ok");
  return Response.json({ status: ok ? "ok" : "failed", database, config, hints, version: process.env.RAILWAY_GIT_COMMIT_SHA?.slice(0, 7) ?? "local", time: new Date().toISOString() }, { status: ok ? 200 : 503 });
}
