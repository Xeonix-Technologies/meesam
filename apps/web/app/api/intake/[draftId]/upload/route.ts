import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { addDraftUpload, getDraft, removeDraftUpload } from "@/lib/records";
import { storeUpload } from "@/lib/upload";
import { deleteObject, vaultConfig } from "@/lib/s3";

export const runtime = "nodejs";

export async function POST(req: Request, { params }: { params: Promise<{ draftId: string }> }) {
  const { draftId } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const draft = await getDraft(auth.session, draftId);
  if (!draft || draft.status !== "open") return go(req, `/${locale}/records`);
  const back = `/${locale}/records/new/${draftId}/5`;

  const remove = form.get("remove");
  if (typeof remove === "string" && remove) {
    if (draft.uploads.some((u) => u.object_key === remove)) {
      await removeDraftUpload(auth.session, draftId, remove);
      try { await deleteObject(vaultConfig(), remove); } catch (err) { console.error(JSON.stringify({ level: "error", at: "vault.delete", message: (err as Error).message })); }
    }
    return go(req, back);
  }

  const file = form.get("file");
  const docType = String(form.get("doc_type") ?? "");
  if (!(file instanceof File)) return go(req, back, { error: "fileType" });
  try {
    const taken = new Set(draft.uploads.map((u) => u.object_key));
    const stored = await storeUpload(file, docType, draft.data.registry_code ?? "XX", draft.data.registration_no ?? null, draft.data.application_no ?? null, taken);
    if ("error" in stored) return go(req, back, { error: stored.error });
    await addDraftUpload(auth.session, draftId, stored);
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "intake.upload", message: (err as Error).message }));
    return go(req, back, { error: "vault" });
  }
  return go(req, back);
}
