import { NextResponse } from "next/server";
import { feedEvents, toIcs } from "@/lib/calendar";
import { publicBase } from "@/lib/guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** The user's calendar feed. No login: the long secret in the link is the key (only its hash is stored). */
export async function GET(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const token = (await params).token.replace(/\.ics$/i, "");
  if (!/^[A-Za-z0-9_-]{30,80}$/.test(token)) return new NextResponse("Not found", { status: 404 });
  const feed = await feedEvents(token).catch(() => null);
  if (!feed) return new NextResponse("Not found", { status: 404 });
  return new NextResponse(toIcs(feed.events, feed.locale, publicBase(req), feed.accountId), {
    headers: { "content-type": "text/calendar; charset=utf-8", "cache-control": "private, max-age=900", "content-disposition": 'inline; filename="meesam.ics"', "x-robots-tag": "noindex" },
  });
}
