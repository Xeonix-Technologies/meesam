import { NextResponse } from "next/server";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { getMarkPageKey } from "@/lib/ops";
import { getObject, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";

/**
 * The gazette page(s) of one published mark, cut out of the issue by the worker (plan item A2), shown to staff of
 * the Operations Console beside what the AI reader read. Staff only; the file comes from the publications bucket.
 */
export async function GET(req: Request) {
  const session = await getSession();
  if (!session) return new NextResponse(null, { status: 404 });
  const roles = await staffRoles(session);
  if (!roles.includes("watch_lead") && !roles.includes("publication_reviewer")) return new NextResponse(null, { status: 404 });
  const q = new URL(req.url).searchParams;
  const issue = q.get("issue") ?? "";
  const mark = q.get("mark") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(issue) || !/^[0-9a-f-]{36}$/.test(mark)) return new NextResponse(null, { status: 404 });
  const key = await getMarkPageKey(issue, mark);
  if (!key) return new NextResponse(null, { status: 404 });
  try {
    const obj = await getObject(vaultConfig("PUBLICATIONS"), key);
    return new NextResponse(new Uint8Array(obj.body), { headers: { "content-type": "application/pdf", "content-disposition": "inline", "cache-control": "private, max-age=600", "x-content-type-options": "nosniff" } });
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "ops.page", message: (e as Error).message }));
    return new NextResponse(null, { status: 404 });
  }
}
