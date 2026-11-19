import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { addManualIssue, MAX_MANUAL_BYTES } from "@/lib/ops";

export const runtime = "nodejs";
export const maxDuration = 300;

/**
 * Temporary collection by hand (Founder ruling 19 Nov 2026): the watch operations lead adds a publication they
 * downloaded from a registry whose site refuses Meesam's fetcher. Only for a source switched to "by hand";
 * the database checks the role and the switch again.
 */
export async function POST(req: Request) {
  const session = await getSession();
  let form: FormData;
  try { form = await req.formData(); } catch { return new NextResponse(null, { status: 400 }); }
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("watch_lead")) return new NextResponse(null, { status: 404 });
  const back = `/${locale}/ops/inbox`;
  const sourceId = String(form.get("source") ?? "");
  const issueNo = String(form.get("issue_no") ?? "").trim().slice(0, 80);
  const publishedOn = String(form.get("published_on") ?? "");
  const file = form.get("file");
  if (!/^[0-9a-f-]{36}$/.test(sourceId) || !issueNo || !(file instanceof File) || file.size === 0) return go(req, back, { error: "required" }, "by-hand");
  if (file.size > MAX_MANUAL_BYTES) return go(req, back, { error: "tooLarge" }, "by-hand");
  const result = await addManualIssue(session, sourceId, issueNo, publishedOn, file.name, Buffer.from(await file.arrayBuffer()));
  return result.ok ? go(req, back, { saved: "added" }) : go(req, back, { error: result.problem }, "by-hand");
}
