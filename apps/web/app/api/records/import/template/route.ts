import { NextResponse } from "next/server";
import { templateCsv } from "@/lib/importer";
import { getSession } from "@/lib/session";

export const runtime = "nodejs";

/** The import template: Meesam's column names and one example row, as CSV that opens in a spreadsheet program. An agency's has the Client column. */
export async function GET() {
  const session = await getSession();
  return new NextResponse(templateCsv(session?.accountKind === "agency_office"), { headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": 'attachment; filename="meesam-import-template.csv"' } });
}
