import { NextResponse } from "next/server";
import { isLocale, type Locale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { heldCorrectionFile, settleCorrection, staffRoles } from "@/lib/staff";
import { sendCorrectionMail } from "@/lib/mail";
import { presignGet, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** System Admin: opens the certificate a held correction is about (a 10-minute link; logged). System administrators only. */
export async function GET(req: Request) {
  const session = await getSession();
  if (!session || !(await staffRoles(session)).includes("system_admin")) return new NextResponse(null, { status: 404 });
  const id = new URL(req.url).searchParams.get("file") ?? "";
  const f = UUID.test(id) ? await heldCorrectionFile(id) : null;
  if (!f) return new NextResponse("Not found", { status: 404 });
  console.log(JSON.stringify({ level: "info", at: "admin.certificates.open", correction: id, by: session.userId }));
  return NextResponse.redirect(presignGet(vaultConfig(), f.object_key, 600, f.file_name), 302);
}

/** System Admin: accepts or rejects a held correction and tells the person who entered it. System administrators only. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("system_admin")) return new NextResponse(null, { status: 404 });
  const back = `/${locale}/admin/certificates`;
  const id = String(form.get("correction_id") ?? "");
  const decision = String(form.get("decision") ?? "");
  const note = String(form.get("note") ?? "").trim().slice(0, 300);
  if (!UUID.test(id) || !["accept", "reject"].includes(decision)) return go(req, back, { error: "generic" });
  if (decision === "reject" && !note) return go(req, back, { error: "noteRequired" });
  try {
    const who = await settleCorrection(session, id, decision === "accept", note);
    if (who) {
      try { await sendCorrectionMail(who.email, who.name, (isLocale(who.locale) ? who.locale : "en") as Locale, decision === "accept" ? "accepted" : "rejected", { mark: "", field: who.field, value: "", note, path: `records/${who.record_id}` }); }
      catch (e) { console.error(JSON.stringify({ level: "error", at: "admin.certificates.mail", message: (e as Error).message })); }
    }
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "admin.certificates", message: ((e as Error & { cause?: Error }).cause ?? (e as Error)).message }));
    return go(req, back, { error: "generic" });
  }
  return go(req, back, { saved: decision === "accept" ? "accepted" : "rejected" });
}
