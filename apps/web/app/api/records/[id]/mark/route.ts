import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { text } from "@/lib/auth";
import { updateMark } from "@/lib/records";

export const runtime = "nodejs";

/** Corrects the mark's type and wording on an existing record (audited; the other side is notified by the database). */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const type = text(form, "mark_type", 10);
  const ar = text(form, "mark_text_ar"), en = text(form, "mark_text_en");
  if (!["word", "device", "combined"].includes(type)) return go(req, back, { tab: "mark", error: "generic" });
  if (type !== "device" && !ar && !en) return go(req, back, { tab: "mark", error: "markText" });
  const mark: Record<string, string> = {};
  if (ar) mark.ar = ar;
  if (en) mark.en = en;
  try {
    await updateMark(auth.session, id, { mark_type: type as "word" | "device" | "combined", mark_text: mark });
  } catch (e) {
    console.error(JSON.stringify({ level: "error", at: "record.mark", message: (e as Error).message }));
    return go(req, back, { tab: "mark", error: "generic" });
  }
  return go(req, back, { tab: "mark", saved: "1" });
}
