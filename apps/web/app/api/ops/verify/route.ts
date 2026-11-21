import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { rejectMark, verifyMark } from "@/lib/ops";

export const runtime = "nodejs";

const UUID = /^[0-9a-f-]{36}$/;

/**
 * The reviewer's queue (plan item A2): a publication reviewer or the watch operations lead confirms one mark read by
 * the AI reader, with the fields as corrected, or removes something that is not a mark. The database checks the
 * role again, keeps what the reader gave beside each correction, and audits both actions.
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  const roles = await staffRoles(session);
  if (!roles.includes("watch_lead") && !roles.includes("publication_reviewer")) return new NextResponse(null, { status: 404 });
  const issue = String(form.get("issue") ?? "");
  const mark = String(form.get("mark") ?? "");
  const next = String(form.get("next") ?? "");
  const action = String(form.get("action") ?? "");
  if (!UUID.test(issue) || !UUID.test(mark)) return go(req, `/${locale}/ops/verify`, { error: "generic" });
  const here = `/${locale}/ops/verify/${issue}`;
  const onward: Record<string, string> = UUID.test(next) ? { m: next } : {};
  const text = (k: string) => String(form.get(k) ?? "");
  try {
    if (action === "reject") {
      const reason = text("reason").trim();
      if (!reason) return go(req, here, { m: mark, error: "verifyReason" });
      await rejectMark(session, issue, mark, reason);
      return go(req, here, { ...onward, saved: "markRemoved" });
    }
    if (action === "confirm") {
      // classes as typed: numbers separated by commas or spaces
      const raw = text("classes").split(/[^0-9]+/).filter(Boolean).map(Number);
      const country = text("applicant_country").trim();
      const filed = text("filing_date").trim();
      if (raw.some((c) => c < 1 || c > 45) || (country && !/^[A-Za-z]{2}$/.test(country)) || (filed && !/^\d{4}-\d{2}-\d{2}$/.test(filed))) return go(req, here, { m: mark, error: "verifyInput" });
      await verifyMark(session, issue, mark, {
        application_no: text("application_no"), filing_date: filed, mark_text_ar: text("mark_text_ar"), mark_text_en: text("mark_text_en"), classes: raw,
        applicant_name: text("applicant_name"), applicant_country: country, agent_name: text("agent_name"), agent_city: text("agent_city"),
      });
      return go(req, here, { ...onward, saved: "markVerified" });
    }
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    const known: Record<string, string> = { "22023": "verifyInput", "22007": "verifyInput", "23505": "verifyNumber", "55000": "verifyDone", "P0002": "verifyDone" };
    const code = err.cause?.code;
    if (code && known[code]) return go(req, here, code === "55000" || code === "P0002" ? { ...onward, error: known[code]! } : { m: mark, error: known[code]! });
    console.error(JSON.stringify({ level: "error", at: "ops.verify", action, message: err.cause?.message ?? err.message }));
  }
  return go(req, here, { m: mark, error: "generic" });
}
