import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { getDraft, saveDraftStep } from "@/lib/records";
import { FILING_STEPS, type FilingData } from "@/lib/filing";

export const runtime = "nodejs";
const str = (f: FormData, k: string, max = 200) => { const v = f.get(k); return typeof v === "string" ? v.trim().slice(0, max) : ""; };
const date = (v: string) => (/^\d{4}-\d{2}-\d{2}$/.test(v) ? (Number(v.slice(0, 4)) < 100 ? `20${v.slice(2)}` : v) : undefined);

/** Saves one step of the filing request (Section 6). Nothing is final until the review step is accepted. */
export async function POST(req: Request, { params }: { params: Promise<{ draftId: string }> }) {
  const { draftId } = await params;
  const form = await req.formData();
  const locale = isLocale(str(form, "locale")) ? str(form, "locale") : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const draft = await getDraft(auth.session, draftId);
  if (!draft || draft.status !== "open" || draft.kind !== "filing") return go(req, `/${locale}/records`);
  const step = Number(str(form, "step"));
  const base = `/${locale}/records/request/${draftId}`;
  const p: FilingData = {};
  if (step === 1) {
    p.applicant_name_ar = str(form, "applicant_name_ar") || undefined; p.applicant_name_en = str(form, "applicant_name_en") || undefined;
    p.legal_form = str(form, "legal_form", 80) || undefined; p.nationality = str(form, "nationality", 2).toUpperCase() || undefined;
    p.address = str(form, "address", 400) || undefined; p.contact_email = str(form, "contact_email", 200) || undefined; p.contact_phone = str(form, "contact_phone", 40) || undefined;
  } else if (step === 2) {
    const registry = str(form, "registry_code", 2).toUpperCase();
    if (!/^[A-Z]{2}$/.test(registry)) return go(req, `${base}/2`, { error: "required" });
    p.registry_code = registry;
    p.route = str(form, "route") === "agency" ? "agency" : "self";
    p.agency_account_id = p.route === "agency" && /^[0-9a-f-]{36}$/.test(str(form, "agency_account_id", 40)) ? str(form, "agency_account_id", 40) : undefined;
    p.agency_named = p.route === "agency" ? str(form, "agency_named", 200) || undefined : undefined;
  } else if (step === 3) {
    const type = str(form, "mark_type");
    if (!["word", "device", "combined"].includes(type)) return go(req, `${base}/3`, { error: "required" });
    p.mark_type = type as FilingData["mark_type"];
    p.mark_text_ar = str(form, "mark_text_ar") || undefined; p.mark_text_en = str(form, "mark_text_en") || undefined;
    p.transliteration = str(form, "transliteration", 300) || undefined; p.translation = str(form, "translation", 300) || undefined;
    p.colour_claim = str(form, "colour_claim", 300) || undefined; p.description = str(form, "description", 1000) || undefined;
  } else if (step === 4) {
    p.classes = form.getAll("classes").map((v) => Number(v)).filter((n) => Number.isInteger(n) && n >= 1 && n <= 45);
    p.headings = form.getAll("heading").map((v) => Number(v)).filter((n) => p.classes!.includes(n));
    p.goods = {};
    for (const n of p.classes) { const g = str(form, `goods_${n}`, 4000); if (g) p.goods[String(n)] = g; }
    // choosing classes re-shows the step so each chosen class gets its goods box
    if (str(form, "refresh") === "1") { await saveDraftStep(auth.session, draftId, step, p as never); return go(req, `${base}/4`); }
  } else if (step === 5) {
    p.priority_claimed = str(form, "priority_claimed") === "yes";
    p.priority_country = str(form, "priority_country", 2).toUpperCase() || undefined;
    p.priority_number = str(form, "priority_number", 60) || undefined; p.priority_date = date(str(form, "priority_date"));
  } else if (step === 6) {
    p.declaration_accuracy = str(form, "declaration_accuracy") === "yes";
  } else return go(req, `${base}/1`);
  await saveDraftStep(auth.session, draftId, step, p as never);
  return go(req, `${base}/${Math.min(step + 1, FILING_STEPS)}`);
}
