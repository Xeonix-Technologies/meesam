import { NextResponse } from "next/server";
import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Terms of one Nice class in force today, filtered by what the user typed (Section 6 group 4: the selectable
 * list of goods and services). The list is WIPO's (migration 0023); languages are data, so a language with no
 * published list falls back to English.
 */
export async function GET(req: Request) {
  const session = await getSession();
  if (!session) return NextResponse.json({ terms: [] }, { status: 401 });
  const url = new URL(req.url);
  const cls = Number(url.searchParams.get("class"));
  const q = (url.searchParams.get("q") ?? "").trim().slice(0, 80);
  const lang = /^[a-z]{2}$/.test(url.searchParams.get("lang") ?? "") ? String(url.searchParams.get("lang")) : "en";
  if (!Number.isInteger(cls) || cls < 1 || cls > 45) return NextResponse.json({ terms: [] });
  const like = `%${q.replace(/[\\%_]/g, (m) => `\\${m}`)}%`;
  const rows = (await withAccount(db(), { accountId: session.accountId, userId: session.userId }, (tx) => tx.execute(sql`
    SELECT t.basic_number, COALESCE(NULLIF(t.term ->> ${lang}, ''), t.term ->> 'en') AS term
      FROM registry.fn_nice_terms(${cls}::smallint) t
     WHERE ${q} = '' OR (t.term ->> 'en') ILIKE ${like} OR (t.term ->> ${lang}) ILIKE ${like} OR t.basic_number = ${q}
     ORDER BY (CASE WHEN (t.term ->> 'en') ILIKE ${`${q}%`} THEN 0 ELSE 1 END), 2
     LIMIT 40`))) as unknown as Array<{ basic_number: string; term: string }>;
  return NextResponse.json({ terms: rows }, { headers: { "cache-control": "no-store" } });
}
