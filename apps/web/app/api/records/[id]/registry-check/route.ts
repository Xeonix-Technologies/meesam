import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { isLocale } from "@meesam/i18n";
import { db } from "@/lib/db";
import { go, requireVerified } from "@/lib/guard";

export const runtime = "nodejs";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * "Verified with registry" is self-declared (Founder ruling 18 Nov 2026): the user states the record was
 * compared with the registry's own record, or withdraws that statement. Who and when are kept (migration 0022).
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  if (!UUID.test(id)) return go(req, `/${locale}/records`);
  const checked = form.get("checked") === "1";
  try {
    await withAccount(db(), { accountId: auth.session.accountId, userId: auth.session.userId }, (tx) => tx.execute(sql`SELECT core.fn_record_registry_check(${id}::uuid, ${checked})`));
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "records.registryCheck", message: (e as Error).message }));
    return go(req, `/${locale}/records/${id}`, { error: "generic" });
  }
  return go(req, `/${locale}/records/${id}`, { saved: "registryCheck" });
}
