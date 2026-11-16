import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { commitDraft, getDraft, saveDraftStep } from "@/lib/records";

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
  const fixes: Record<string, string> = {};
  for (const [k, v] of form.entries()) {
    if (typeof v !== "string") continue;
    if (k.startsWith("confirm:") && v.trim()) confirmations[k.slice(8)] = v.trim().slice(0, 300);
    if (k.startsWith("fix:") && v.trim()) fixes[k.slice(4)] = v.trim().slice(0, 60);
  }
  // values typed on the review page correct the draft before anything is created
  const DATE_FIELDS = ["filing_date", "acceptance_date", "publication_date", "opposition_end", "registration_date", "expiry_date", "renewal_date"];
  const TEXT_FIELDS = ["application_no", "registration_no"];
  const patch: Record<string, string> = {};
  for (const [field, value] of Object.entries(fixes)) {
    if (DATE_FIELDS.includes(field) && /^\d{4}-\d{2}-\d{2}$/.test(value)) patch[field] = value;
    if (TEXT_FIELDS.includes(field)) patch[field] = value;
  }
  if (Object.keys(patch).length) {
    await saveDraftStep(auth.session, draftId, 6, patch);
    Object.assign(draft.data, patch);
  }
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
