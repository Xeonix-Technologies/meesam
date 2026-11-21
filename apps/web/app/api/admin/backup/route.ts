import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { requestBackup, staffRoles } from "@/lib/staff";

export const runtime = "nodejs";

/** System Admin → Backups: ask the worker for a second copy of the database now, with or without a restore test. System administrators only. */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("system_admin")) return new NextResponse(null, { status: 404 });
  const back = `/${locale}/admin/backups`;
  try {
    await requestBackup(session, String(form.get("action") ?? "") === "restore_test");
    return go(req, back, { saved: "requested" });
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    if (err.cause?.code === "55006") return go(req, back, { error: "busy" });
    console.error(JSON.stringify({ level: "error", at: "admin.backup", message: err.cause?.message ?? err.message }));
    return go(req, back, { error: "generic" });
  }
}
