import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { addDraftUpload, getDraft, removeDraftUpload, replaceDraftData, setDraftUploadExtraction } from "@/lib/records";
import { extractionConfigured, mergeExtraction, readDocument } from "@/lib/extract";
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
  const filing = draft.kind === "filing";
  const stepRaw = Number(form.get("return_step"));
  const back = filing ? `/${locale}/records/request/${draftId}/${[3, 6].includes(stepRaw) ? stepRaw : 6}` : `/${locale}/records/new/${draftId}/5`;

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
  const purpose0 = String(form.get("purpose") ?? "");
  if (!(file instanceof File)) return go(req, back, { error: "fileType" });
  try {
    const taken = new Set(draft.uploads.map((u) => u.object_key));
    const stored = await storeUpload(file, purpose0 === "mark_image" ? "IMG" : docType, draft.data.registry_code ?? "XX", draft.data.registration_no ?? null, draft.data.application_no ?? null, taken);
    if ("error" in stored) return go(req, back, { error: stored.error });
    const purpose = String(form.get("purpose") ?? "");
    await addDraftUpload(auth.session, draftId, purpose === "mark_image" ? { ...stored, purpose } : stored);
    if (filing) return go(req, back); // a filing request's attachments are not read: its fields are typed by the applicant
    // the reader fills what the document states; the user reviews every field before anything is saved (4.7 step 7)
    if (!extractionConfigured()) { await setDraftUploadExtraction(auth.session, draftId, stored.object_key, null, "skipped"); return go(req, back, { notice: "noReader" }); }
    try {
      const ex = await readDocument(stored);
      if (!ex) { await setDraftUploadExtraction(auth.session, draftId, stored.object_key, null, "skipped"); return go(req, back); }
      const fresh = await getDraft(auth.session, draftId);
      const merged = mergeExtraction(fresh?.data ?? draft.data, ex, stored.file_name);
      await replaceDraftData(auth.session, draftId, merged.data);
      await setDraftUploadExtraction(auth.session, draftId, stored.object_key, ex, "extracted");
      return go(req, back, { notice: merged.filled.length ? "read" : "readNothing", n: String(merged.filled.length) });
    } catch (err) {
      console.error(JSON.stringify({ level: "error", at: "intake.read", message: (err as Error).message }));
      await setDraftUploadExtraction(auth.session, draftId, stored.object_key, null, "failed");
      return go(req, back, { notice: "readFailed" });
    }
  } catch (err) {
    console.error(JSON.stringify({ level: "error", at: "intake.upload", message: (err as Error).message }));
    return go(req, back, { error: "vault" });
  }
}
