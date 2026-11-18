import { NextResponse } from "next/server";
import { getSession } from "@/lib/session";
import { pendingAppointmentCount } from "@/lib/appointments";
import { unreadByRecord } from "@/lib/messages";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Counts for the side navigation, re-read by the browser after each navigation (see components/NavCounts). */
export async function GET() {
  const session = await getSession();
  const none = { requests: 0, unread: {} };
  if (!session || session.verificationStatus !== "verified") return NextResponse.json(none, { headers: { "cache-control": "no-store" } });
  const [requests, unread] = await Promise.all([pendingAppointmentCount(session).catch(() => 0), unreadByRecord(session).catch(() => [])]);
  return NextResponse.json({ requests, unread: Object.fromEntries(unread.map((u) => [u.record_id, u.n])) }, { headers: { "cache-control": "no-store" } });
}
