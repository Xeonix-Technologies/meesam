import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { addFromMail, discardMail } from "@/lib/ops";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";

export const runtime = "nodejs";
export const maxDuration = 300;

/** Publications inbox → "Received by e-mail": the watch operations lead adds a waiting file to a source collected by hand, or discards it. */
export async function POST(req: Request) {
  const session = await getSession();
  let form: FormData;
  try { form = await req.formData(); } catch { return new NextResponse(null, { status: 400 }); }
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("watch_lead")) return new NextResponse(null, { status: 404 });
  const back = `/${locale}/ops/inbox`;
  const id = String(form.get("id") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(id)) return new NextResponse(null, { status: 400 });
  if (String(form.get("do") ?? "") === "discard") {
    return (await discardMail(session, id)) ? go(req, back, { saved: "mailDiscarded" }) : go(req, back, { error: "generic" }, "by-mail");
  }
  const sourceId = String(form.get("source") ?? "");
  const issueNo = String(form.get("issue_no") ?? "").trim().slice(0, 80);
  const publishedOn = String(form.get("published_on") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(sourceId) || !issueNo) return go(req, back, { error: "required" }, "by-mail");
  const result = await addFromMail(session, id, sourceId, issueNo, publishedOn);
  return result.ok ? go(req, back, { saved: "added" }) : go(req, back, { error: result.problem }, "by-mail");
}
