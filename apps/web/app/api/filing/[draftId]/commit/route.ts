import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { getDraft } from "@/lib/records";
import { commitFiling } from "@/lib/filing";

export const runtime = "nodejs";

/** Review and acceptance of the filing request (Sections 4.7 and 6): creates the record at stage 1, pre-filing. */
export async function POST(req: Request, { params }: { params: Promise<{ draftId: string }> }) {
  const { draftId } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const draft = await getDraft(auth.session, draftId);
  if (!draft || draft.kind !== "filing") return go(req, `/${locale}/records`);
  if (draft.status === "committed" && draft.record_id) return go(req, `/${locale}/records/${draft.record_id}`);
  const back = `/${locale}/records/request/${draftId}/7`;
  if (form.get("accept") !== "yes") return go(req, back, { error: "accept" });
  const d = draft.data as { registry_code?: string; mark_type?: string };
  if (!d.registry_code || !d.mark_type) return go(req, back, { error: "incomplete" });
  const confirmations: Record<string, string> = {};
  for (const [k, v] of form.entries()) if (k.startsWith("confirm:") && typeof v === "string" && v.trim()) confirmations[k.slice(8)] = v.trim().slice(0, 300);
  try {
    const id = await commitFiling(auth.session, draft, confirmations);
    return go(req, `/${locale}/records/${id}`, { tab: "request", created: "1" });
  } catch (e) {
    const err = e as Error & { cause?: { message?: string; code?: string } };
    console.error(JSON.stringify({ level: "error", at: "filing.commit", message: err.message, cause: err.cause?.message, code: err.cause?.code }));
    return go(req, back, { error: err.cause?.code === "23505" ? "duplicate" : "generic" });
  }
}
