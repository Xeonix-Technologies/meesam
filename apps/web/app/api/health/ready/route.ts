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
  const ok = database === "ok" && Object.values(config).every((v) => v === "ok");
  return Response.json({ status: ok ? "ok" : "failed", database, config, version: process.env.RAILWAY_GIT_COMMIT_SHA?.slice(0, 7) ?? "local", time: new Date().toISOString() }, { status: ok ? 200 : 503 });
}
