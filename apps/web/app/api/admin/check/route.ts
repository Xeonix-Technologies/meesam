import { NextResponse } from "next/server";
import { sql } from "drizzle-orm";
import { deleteObject, getObject, putObject, vaultConfig, withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { signupOpen } from "@/lib/signup";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * System check for a System Administrator: does this web service reach everything it depends on, with the values
 * it was given? Each line is "ok" or a short reason; no value of any setting is shown. It writes one small file
 * to each bucket and removes it, and asks the e-mail and AI providers only whether the key is accepted (no e-mail
 * is sent and nothing is paid). Not public: these checks cost outside calls.
 */
const short = (e: unknown) => {
  const err = e as { code?: string; cause?: { code?: string; message?: string }; message?: string };
  return String(err.cause?.code ?? err.code ?? err.cause?.message ?? err.message ?? "failed").replace(/https?:\/\/\S+/g, "(address)").slice(0, 140);
};
const within = <T>(p: Promise<T>, ms = 8000): Promise<T> => Promise.race([p, new Promise<T>((_, no) => setTimeout(() => no(new Error("no answer in 8 seconds")), ms))]);

async function bucket(prefix: "VAULT" | "PUBLICATIONS"): Promise<string> {
  let cfg;
  try { cfg = vaultConfig(prefix); } catch { return `not set on this service (${prefix}_BUCKET, _ENDPOINT, _ACCESS_KEY_ID, _SECRET_ACCESS_KEY)`; }
  const key = `_check/${Date.now()}.txt`;
  try {
    await within(putObject(cfg, key, Buffer.from("meesam system check"), "text/plain"));
    const back = await within(getObject(cfg, key));
    await within(deleteObject(cfg, key));
    return back.body.toString() === "meesam system check" ? "ok" : "failed: the file read back differs from the file written";
  } catch (e) { return `failed: ${short(e)}`; }
}

async function accepted(name: string, url: string, headers: Record<string, string>): Promise<string> {
  try {
    const res = await within(fetch(url, { headers }));
    if (res.ok) return "ok";
    return res.status === 401 || res.status === 403 ? `failed: the provider does not accept the value of ${name} (${res.status})` : `failed: the provider answered ${res.status}`;
  } catch (e) { return `failed: ${short(e)}`; }
}

export async function GET() {
  const session = await getSession();
  if (!session || !(await staffRoles(session)).includes("system_admin")) return new NextResponse(null, { status: 404 });

  let database = "ok";
  try { await within(withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT 1`))); } catch (e) { database = `failed: ${short(e)}`; }
  const mailKey = process.env.EMAIL_PROVIDER_KEY, aiKey = process.env.AI_PROVIDER_KEY;
  const [vault, publications, email, ai] = await Promise.all([
    bucket("VAULT"), bucket("PUBLICATIONS"),
    mailKey ? accepted("EMAIL_PROVIDER_KEY", "https://api.postmarkapp.com/server", { accept: "application/json", "X-Postmark-Server-Token": mailKey }) : Promise.resolve("not set (EMAIL_PROVIDER_KEY)"),
    aiKey ? accepted("AI_PROVIDER_KEY", "https://api.anthropic.com/v1/models?limit=1", { "x-api-key": aiKey, "anthropic-version": "2023-06-01" }) : Promise.resolve("not set (AI_PROVIDER_KEY)"),
  ]);
  const checks = {
    database,
    documents_bucket: vault,
    publications_bucket: publications,
    email_provider: email,
    ai_provider: ai,
    email_from: /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test((process.env.EMAIL_FROM ?? "").replace(/^.*<([^>]+)>\s*$/, "$1").trim()) ? "ok" : "failed: EMAIL_FROM is not an e-mail address",
    two_step_key: process.env.TWO_FACTOR_KEY ? "ok" : "not set (TWO_FACTOR_KEY)",
    first_administrators: (process.env.SYSTEM_ADMIN_EMAILS ?? "").includes("@") ? "ok" : "not set (SYSTEM_ADMIN_EMAILS)",
  };
  const ok = Object.values(checks).every((v) => v === "ok");
  return NextResponse.json({
    status: ok ? "ok" : "attention",
    checks,
    sign_up: signupOpen() ? "open" : "closed",
    service: "web",
    note: "The worker has its own copies of the bucket, AI and backup settings; its backup is tested on the Backups page.",
    version: process.env.RAILWAY_GIT_COMMIT_SHA?.slice(0, 7) ?? "local",
    time: new Date().toISOString(),
  }, { status: 200 });
}
