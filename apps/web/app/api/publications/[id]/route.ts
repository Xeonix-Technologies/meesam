import { NextResponse } from "next/server";
import { presignGet, vaultConfig } from "@/lib/s3";
import { sharedIssueFile } from "@/lib/publications";
import { getSession } from "@/lib/session";

export const runtime = "nodejs";

/**
 * A signed-in account downloads an issue of a registry whose publications are shown to accounts (migration 0100).
 * The database says whether this issue may be given; the file is the one the registry published, unchanged, handed
 * over by a link that lasts ten minutes.
 */
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const session = await getSession();
  if (!session || !/^[0-9a-f-]{36}$/.test(id)) return new NextResponse(null, { status: 404 });
  if (!session.isStaff && session.verificationStatus !== "verified") return new NextResponse(null, { status: 404 });
  const f = await sharedIssueFile(id);
  if (!f) return new NextResponse(null, { status: 404 });
  let bucket;
  try { bucket = vaultConfig("PUBLICATIONS"); } catch { return new NextResponse(null, { status: 503 }); }
  const name = `${f.registry_code}-${f.issue_no.replace(/[^0-9A-Za-z._-]/g, "_")}.${f.container.replace(/[^a-z0-9]/g, "")}`;
  return NextResponse.redirect(presignGet(bucket, f.object_key, 600, name), 302);
}
