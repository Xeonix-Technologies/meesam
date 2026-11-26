import { createHash, timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import { sql } from "drizzle-orm";
import { putObject, vaultConfig, withRole } from "@meesam/db";
import { db } from "@/lib/db";

export const runtime = "nodejs";
export const maxDuration = 300;

const MAX_FILES = 10;
const say = (level: string, message: string, more: Record<string, unknown> = {}) => console[level === "error" ? "error" : "log"](JSON.stringify({ level, at: "inbound.publications", message, ...more }));

/** PDF, ZIP or RAR by the file's own first bytes; anything else in a message (signatures, pictures, text) is left. */
function kindOf(b: Buffer): "pdf" | "zip" | "rar" | null {
  if (b.length < 8) return null;
  if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) return "pdf";
  if (b[0] === 0x50 && b[1] === 0x4b && (b[2] === 0x03 || b[2] === 0x05)) return "zip";
  if (b[0] === 0x52 && b[1] === 0x61 && b[2] === 0x72 && b[3] === 0x21) return "rar";
  return null;
}
function allowed(sender: string): boolean {
  const list = (process.env.INBOUND_MAIL_SENDERS ?? "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
  const s = sender.trim().toLowerCase();
  return list.some((x) => (x.startsWith("@") ? s.endsWith(x) : s === x));
}

/**
 * Publications received by e-mail (Founder, 26 Nov 2026: a trial on staging before he rules; migration 0096).
 * The mail provider posts each message received at Meesam's publications address here. The route answers only
 * where INBOUND_MAIL_KEY is set, only to the provider's call carrying that key (HTTP Basic, never in the address),
 * and keeps files only from the senders named in INBOUND_MAIL_SENDERS. A file kept here WAITS: it is stored under
 * _mail/ in the publications bucket and listed for the watch operations lead, who adds it to a source collected
 * by hand (where it is checked like any file added by hand) or discards it. Nothing is read from a waiting file.
 */
export async function POST(req: Request) {
  const key = (process.env.INBOUND_MAIL_KEY ?? "").trim();
  if (key.length < 24) return new NextResponse(null, { status: 404 });
  const given = /^Basic\s+(.+)$/i.exec(req.headers.get("authorization") ?? "")?.[1] ?? "";
  const pass = Buffer.from(given, "base64").toString("utf8").split(":").slice(1).join(":");
  const a = createHash("sha256").update(pass).digest(), b = createHash("sha256").update(key).digest();
  if (!timingSafeEqual(a, b)) return new NextResponse(null, { status: 401 });
  let m: { From?: string; FromFull?: { Email?: string }; Subject?: string; Attachments?: Array<{ Name?: string; Content?: string }> };
  try { m = await req.json(); } catch { return new NextResponse(null, { status: 400 }); }
  const sender = String(m.FromFull?.Email ?? m.From ?? "").slice(0, 200);
  // From here the provider is always answered 200: a refusal must not make it send the message again and again.
  if (!allowed(sender)) { say("warn", "a message from a sender not on the list was left", { sender }); return NextResponse.json({ kept: 0 }); }
  let bucket;
  try { bucket = vaultConfig("PUBLICATIONS"); } catch { say("error", "the publications bucket is not configured"); return NextResponse.json({ kept: 0 }); }
  let kept = 0;
  for (const att of (Array.isArray(m.Attachments) ? m.Attachments : []).slice(0, MAX_FILES)) {
    try {
      const body = Buffer.from(String(att.Content ?? ""), "base64");
      const kind = kindOf(body);
      if (!kind) continue;
      const sha = createHash("sha256").update(body).digest("hex");
      const name = (String(att.Name ?? "").replace(/[^\p{L}\p{N}._ -]/gu, "_").slice(-150) || `file.${kind}`);
      const objectKey = `_mail/${sha}.${kind}`;
      await putObject(bucket, objectKey, body, kind === "pdf" ? "application/pdf" : "application/octet-stream");
      await withRole(db(), "meesam_admin", (tx) => tx.execute(sql`SELECT watch.fn_mail_intake_receive(${sender}, ${String(m.Subject ?? "")}, ${name}, ${body.length}::bigint, decode(${sha}, 'hex'), ${objectKey})`));
      kept += 1;
    } catch (e) { say("error", (e as Error).message.slice(0, 300), { sender }); }
  }
  say("info", "a message was received", { sender, kept });
  return NextResponse.json({ kept });
}
