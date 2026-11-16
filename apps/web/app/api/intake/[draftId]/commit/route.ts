import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { commitDraft, getDraft } from "@/lib/records";

export const runtime = "nodejs";

/** Step 7: accept. Every warning either corrected (user went back) or confirmed with a note. */
export async function POST(req: Request, { params }: { params: Promise<{ draftId: string }> }) {
  const { draftId } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const draft = await getDraft(auth.session, draftId);
  if (!draft) return go(req, `/${locale}/records`);
  if (draft.status === "committed" && draft.record_id) return go(req, `/${locale}/records/${draft.record_id}`);
  const confirmations: Record<string, string> = {};
  for (const [k, v] of form.entries()) if (k.startsWith("confirm:") && typeof v === "string") confirmations[k.slice(8)] = v.trim().slice(0, 300);
  if (form.get("accept") !== "yes") return go(req, `/${locale}/records/new/${draftId}/6`, { error: "accept" });
  try {
    const recordId = await commitDraft(auth.session, draft, confirmations);
    return go(req, `/${locale}/records/${recordId}`, { created: "1" });
  } catch (err) {
    const e = err as Error & { cause?: { message?: string; code?: string } };
    console.error(JSON.stringify({ level: "error", at: "intake.commit", message: e.message, cause: e.cause?.message, code: e.cause?.code, stage: draft.data.stage, registry: draft.data.registry_code }));
    return go(req, `/${locale}/records/new/${draftId}/6`, { error: "generic" });
  }
}
