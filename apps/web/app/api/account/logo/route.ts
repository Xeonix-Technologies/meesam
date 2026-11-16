import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { accountLogoKey, setAccountLogo } from "@/lib/account";
import { getObject, putObject, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";

const TYPES: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" };
const MAX_BYTES = 2 * 1024 * 1024;

/** Streams the signed-in account's logo (the key is never exposed; the file is private in the vault). */
export async function GET() {
  const session = await getSession();
  if (!session) return new NextResponse(null, { status: 401 });
  const key = await accountLogoKey(session);
  if (!key) return new NextResponse(null, { status: 404 });
  const obj = await getObject(vaultConfig(), key);
  return new NextResponse(new Uint8Array(obj.body), { headers: { "content-type": obj.contentType ?? "image/png", "cache-control": "private, max-age=300", "content-disposition": "inline" } });
}

/**
 * Upload (administrators only). Stored under accounts/<account id>/logo_<timestamp>.<ext> in the vault
 * bucket — an account asset, not a record document, so the item 43 naming scheme does not apply.
 * Earlier logos are left in place (nothing is deleted from the vault); only the pointer moves.
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/settings`;
  if (auth.session.role !== "company_admin" && auth.session.role !== "agency_admin") return go(req, back, { error: "adminOnly" });
  if (form.get("remove") === "1") {
    await setAccountLogo(auth.session, null);
    return go(req, back, { saved: "logo" });
  }
  const file = form.get("file");
  if (!(file instanceof File) || !TYPES[file.type]) return go(req, back, { error: "imageType", field: "logo" });
  if (file.size === 0 || file.size > MAX_BYTES) return go(req, back, { error: "logoSize", field: "logo" });
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 12);
  const key = `accounts/${auth.session.accountId}/logo_${stamp}.${TYPES[file.type]}`;
  try {
    await putObject(vaultConfig(), key, Buffer.from(await file.arrayBuffer()), file.type);
    await setAccountLogo(auth.session, key);
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "account.logo", message: (e as Error).message }));
    return go(req, back, { error: "vault" });
  }
  return go(req, back, { saved: "logo" });
}
