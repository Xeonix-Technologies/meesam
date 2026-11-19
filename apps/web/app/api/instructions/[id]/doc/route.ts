import { NextResponse } from "next/server";
import { requireVerified } from "@/lib/guard";
import { instructionDoc } from "@/lib/instructions";
import { presignGet, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";

/** A document attached to a cross-border instruction (legal request or power of attorney): a 10-minute presigned link, if the database lets this account open it. */
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const auth = await requireVerified(req, "en");
  if ("response" in auth) return auth.response;
  const which = new URL(req.url).searchParams.get("which") === "legal" ? "legal" : "poa";
  if (!/^[0-9a-f-]{36}$/.test(id)) return new NextResponse("Not found", { status: 404 });
  const doc = await instructionDoc(auth.session, id, which).catch(() => null);
  if (!doc) return new NextResponse("Not found", { status: 404 });
  return NextResponse.redirect(presignGet(vaultConfig(), doc.object_key, 600, doc.file_name), 302);
}
