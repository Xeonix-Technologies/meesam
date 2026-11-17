import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { correctClasses } from "@/lib/records";

export const runtime = "nodejs";

/**
 * Corrects the classes already on a record: the class number and the goods or services as filed.
 * It never adds a class (Founder, 17 Nov 2026): adding one is a paid action of the Business Model
 * and comes with the payment step.
 */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const rows: Array<{ id: string; number: number; goods: string }> = [];
  for (const cid of form.getAll("class_id")) {
    if (typeof cid !== "string" || !/^[0-9a-f-]{36}$/.test(cid)) continue;
    const number = Number(form.get(`number:${cid}`));
    const goods = String(form.get(`goods:${cid}`) ?? "").trim().slice(0, 4000);
    if (!Number.isInteger(number) || number < 1 || number > 45) return go(req, back, { tab: "mark", error: "classRange" });
    rows.push({ id: cid, number, goods });
  }
  if (new Set(rows.map((r) => r.number)).size !== rows.length) return go(req, back, { tab: "mark", error: "classDuplicate" });
  try {
    await correctClasses(auth.session, id, rows);
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "record.classes", message: (e as Error).message }));
    return go(req, back, { tab: "mark", error: "generic" });
  }
  return go(req, back, { tab: "mark", saved: "1" });
}
