import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { timerEvent, toIcs } from "@/lib/calendar";
import { publicBase, requireVerified } from "@/lib/guard";

export const runtime = "nodejs";

/** "Add to calendar" for one deadline: a one-event calendar file (System Description 4.11: any deadline can be added to a calendar). */
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const l = new URL(req.url).searchParams.get("locale") ?? "";
  const locale = isLocale(l) ? l : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  if (!/^[0-9a-f-]{36}$/.test(id)) return new NextResponse("Not found", { status: 404 });
  const ev = await timerEvent(auth.session, id);
  if (!ev) return new NextResponse("Not found", { status: 404 });
  return new NextResponse(toIcs([ev], locale, publicBase(req)), {
    headers: { "content-type": "text/calendar; charset=utf-8", "content-disposition": 'attachment; filename="meesam-deadline.ics"', "cache-control": "private, no-store" },
  });
}
