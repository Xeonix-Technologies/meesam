import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { getDocument, removeDocument } from "@/lib/records";
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

/** Remove a document from its record (administrators only; the database decides). The file is kept and the removal audited. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const recordId = String(form.get("record_id") ?? "");
  const back = /^[0-9a-f-]{36}$/.test(recordId) ? `/${locale}/records/${recordId}` : `/${locale}/records`;
  if (form.get("action") !== "remove" || !/^[0-9a-f-]{36}$/.test(id)) return go(req, back, { tab: "documents", error: "docRemove" });
  try { await removeDocument(auth.session, id); }
  catch (e) {
    console.error(JSON.stringify({ level: "error", at: "document.remove", message: (e as Error).message }));
    return go(req, back, { tab: "documents", error: "docRemove" });
  }
  return go(req, back, { tab: "documents", saved: "docRemoved" });
}
