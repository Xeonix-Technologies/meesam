import { NextResponse } from "next/server";
import { getSession } from "@/lib/session";
import { pendingAppointmentCount } from "@/lib/appointments";
import { unreadByRecord } from "@/lib/messages";
import { pendingInstructionCount } from "@/lib/instructions";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Counts for the side navigation, re-read by the browser after each navigation (see components/NavCounts). */
export async function GET() {
  const session = await getSession();
  const none = { requests: 0, instructions: 0, unread: {} };
  if (!session || session.verificationStatus !== "verified") return NextResponse.json(none, { headers: { "cache-control": "no-store" } });
  const [requests, unread, instructions] = await Promise.all([pendingAppointmentCount(session).catch(() => 0), unreadByRecord(session).catch(() => []), pendingInstructionCount(session).catch(() => 0)]);
  return NextResponse.json({ requests, instructions, unread: Object.fromEntries(unread.map((u) => [u.record_id, u.n])) }, { headers: { "cache-control": "no-store" } });
}
