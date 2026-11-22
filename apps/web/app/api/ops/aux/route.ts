import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { getMarkAux } from "@/lib/ops";

export const runtime = "nodejs";

/**
 * The reviewer's queue asks here, every few seconds, whether the translation and the gazette page(s) of the mark
 * it shows have arrived. Staff of the Operations Console only; nothing is changed by asking.
 */
export async function GET(req: Request) {
  const session = await getSession();
  if (!session) return new NextResponse(null, { status: 404 });
  const roles = await staffRoles(session);
  if (!roles.includes("watch_lead") && !roles.includes("publication_reviewer")) return new NextResponse(null, { status: 404 });
  const q = new URL(req.url).searchParams;
  const issue = q.get("issue") ?? "", mark = q.get("mark") ?? "", lang = q.get("lang") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(issue) || !/^[0-9a-f-]{36}$/.test(mark) || !isLocale(lang)) return new NextResponse(null, { status: 404 });
  const aux = await getMarkAux(issue, mark, lang);
  if (!aux) return new NextResponse(null, { status: 404 });
  return NextResponse.json(aux, { headers: { "cache-control": "no-store" } });
}
