import { NextResponse } from "next/server";
import { requireVerified } from "@/lib/guard";
import { getDocument } from "@/lib/records";
import { getObject, presignGet, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";

/** Access is checked by RLS (the document row is visible only to accounts holding the record); then a 10-minute presigned link. */
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const auth = await requireVerified(req, "en");
  if ("response" in auth) return auth.response;
  const doc = await getDocument(auth.session, id);
  if (!doc) return new NextResponse("Not found", { status: 404 });
  // Images shown in the page (mark representation) are streamed through the app so <img> works
  // without a cross-origin redirect; everything else is a short-lived presigned download link.
  if (new URL(req.url).searchParams.has("inline") && doc.content_type?.startsWith("image/")) {
    const obj = await getObject(vaultConfig(), doc.object_key);
    return new NextResponse(new Uint8Array(obj.body), { headers: { "content-type": obj.contentType ?? doc.content_type, "cache-control": "private, max-age=300", "content-disposition": "inline" } });
  }
  return NextResponse.redirect(presignGet(vaultConfig(), doc.object_key, 600, doc.file_name), 302);
}
