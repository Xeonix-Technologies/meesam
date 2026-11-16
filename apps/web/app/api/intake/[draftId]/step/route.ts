import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { getDraft, saveDraftStep } from "@/lib/records";
import { INTAKE_STAGES, type IntakeData } from "@/lib/checks";

export const runtime = "nodejs";
const str = (f: FormData, k: string, max = 200) => { const v = f.get(k); return typeof v === "string" ? v.trim().slice(0, max) : ""; };
const dateOrUndef = (v: string) => (/^\d{4}-\d{2}-\d{2}$/.test(v) ? v : undefined);

/** Saves one intake step and moves to the next (System Description 4.7). Nothing is final until step 7. */
export async function POST(req: Request, { params }: { params: Promise<{ draftId: string }> }) {
  const { draftId } = await params;
  const form = await req.formData();
  const locale = isLocale(str(form, "locale")) ? str(form, "locale") : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const draft = await getDraft(auth.session, draftId);
  if (!draft || draft.status !== "open") return go(req, `/${locale}/records`);
  const step = Number(str(form, "step"));
  const base = `/${locale}/records/new/${draftId}`;
  const patch: Partial<IntakeData> = {};

  if (step === 1) {
    const manager = str(form, "manager");
    patch.manager = manager === "agency" ? "agency" : "self";
    if (patch.manager === "agency") patch.agency_account_id = str(form, "agency_account_id", 40) || undefined;
  } else if (step === 2) {
    const registry = str(form, "registry_code", 2).toUpperCase();
    const stage = str(form, "stage");
    if (!/^[A-Z]{2}$/.test(registry) || !(INTAKE_STAGES as string[]).includes(stage)) return go(req, `${base}/2`, { error: "required" });
    patch.registry_code = registry;
    patch.stage = stage as IntakeData["stage"];
  } else if (step === 3) {
    const type = str(form, "mark_type");
    if (!["word", "device", "combined"].includes(type)) return go(req, `${base}/3`, { error: "required" });
    patch.mark_type = type as IntakeData["mark_type"];
    patch.mark_text_ar = str(form, "mark_text_ar") || undefined;
    patch.mark_text_en = str(form, "mark_text_en") || undefined;
    patch.classes = form.getAll("classes").map((v) => Number(v)).filter((n) => Number.isInteger(n));
    patch.goods = str(form, "goods", 4000) || undefined;
    if (type !== "device" && !patch.mark_text_ar && !patch.mark_text_en) return go(req, `${base}/3`, { error: "markText" });
  } else if (step === 4) {
    patch.application_no = str(form, "application_no", 60) || undefined;
    patch.filing_date = dateOrUndef(str(form, "filing_date"));
    patch.acceptance_date = dateOrUndef(str(form, "acceptance_date"));
    patch.publication_date = dateOrUndef(str(form, "publication_date"));
    patch.opposition_end = dateOrUndef(str(form, "opposition_end"));
    patch.registration_no = str(form, "registration_no", 60) || undefined;
    patch.registration_date = dateOrUndef(str(form, "registration_date"));
    patch.expiry_date = dateOrUndef(str(form, "expiry_date"));
    patch.renewal_date = dateOrUndef(str(form, "renewal_date"));
  } else if (step === 5) {
    // documents are added by the upload handler; this just advances
  } else {
    return go(req, `${base}/1`);
  }
  await saveDraftStep(auth.session, draftId, step, patch);
  return go(req, `${base}/${Math.min(step + 1, 6)}`);
}
