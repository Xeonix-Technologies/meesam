import { NextResponse } from "next/server";
import { templateCsv } from "@/lib/importer";

export const runtime = "nodejs";

/** The import template: Meesam's column names and one example row, as CSV that opens in a spreadsheet program. */
export async function GET() {
  return new NextResponse(templateCsv(), { headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": 'attachment; filename="meesam-import-template.csv"' } });
}
