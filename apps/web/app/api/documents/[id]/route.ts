import { NextResponse } from "next/server";
import { requireVerified } from "@/lib/guard";
import { getDocument } from "@/lib/records";
import { presignGet, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";

/** Access is checked by RLS (the document row is visible only to accounts holding the record); then a 10-minute presigned link. */
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const auth = await requireVerified(req, "en");
  if ("response" in auth) return auth.response;
  const doc = await getDocument(auth.session, id);
  if (!doc) return new NextResponse("Not found", { status: 404 });
  return NextResponse.redirect(presignGet(vaultConfig(), doc.object_key, 600, doc.file_name), 302);
}
