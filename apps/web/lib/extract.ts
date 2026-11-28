import { getObject, vaultConfig } from "./s3";
import type { Upload } from "./records";
import type { IntakeData } from "./checks";

/**
 * Document reader (System Description 4.7 step 5 and item 21; Data Architecture Section 13 pipeline 1).
 * Reads an uploaded registry document with the configured AI provider and returns the fields it found,
 * each with the passage it came from, so the reviewer can check at a glance (4.7 step 7). Nothing here
 * writes to the record: the account holder reviews and accepts every field on the review step.
 *
 * Provider: Anthropic Messages API, key in AI_PROVIDER_KEY, model in AI_MODEL (configuration, not code).
 * Founder ruling 16 Nov 2026: the certificate is asked for first and the form is filled from it.
 */
export const EXTRACT_FIELDS = [
  "registry_code", "stage", "mark_type", "mark_text_ar", "mark_text_en", "classes", "goods",
  "application_no", "filing_date", "acceptance_date", "publication_date", "opposition_end",
  "registration_no", "registration_date", "expiry_date", "renewal_date", "owner_name",
] as const;
export type ExtractField = (typeof EXTRACT_FIELDS)[number];
export interface ExtractedField { value: string | number | number[] | null; source: string | null; confidence: number }
export interface Extraction { fields: Partial<Record<ExtractField, ExtractedField>>; model: string; read_at: string; document_kind?: string | null; notes?: string | null;
  /** what the reading used, as the provider reports it (for the cost report) */
  usage?: { input_tokens: number | null; output_tokens: number | null } }
export type Sources = Partial<Record<string, { file: string; quote: string | null; confidence: number }>>;

const SYSTEM = `You read trademark registry documents (certificates, filing receipts, acceptance and publication notices, renewal certificates) issued by national or regional trademark offices, often in Arabic and English. Return only JSON, no prose.`;

const prompt = () => `Extract the fields below from the attached document. Return a single JSON object:
{"document_kind": "<certificate|application_receipt|acceptance_notice|publication|renewal|power_of_attorney|other>",
 "fields": { "<field>": {"value": <value or null>, "source": "<the exact short passage in the document the value came from, or null>", "confidence": <0..1>} },
 "notes": "<anything unusual, or null>"}
Fields and formats:
- registry_code: ISO 3166-1 alpha-2 / WIPO ST.3 code of the issuing office (UAE Ministry of Economy -> "AE"; Saudi SAIP -> "SA"; EUIPO -> "EM"; USPTO -> "US"; WIPO international registration -> "WO").
- stage: the stage this document evidences: one of filed, accepted, published, fee_paid, registered, renewed.
- mark_type: word, device or combined (word + figurative element).
- mark_text_ar: the mark's Arabic wording as printed, or null. mark_text_en: the Latin-script wording, or null.
- classes: array of Nice class numbers (integers 1..45).
- goods: the goods/services specification as printed (one string; Arabic or English as printed; keep it short if very long).
- application_no, registration_no: as printed (digits/characters only, no labels).
- filing_date, acceptance_date, publication_date, opposition_end, registration_date, expiry_date, renewal_date: ISO dates YYYY-MM-DD; convert Hijri or dd/mm/yyyy as needed; null when absent.
- owner_name: the proprietor as printed.
Only include a field when the document states it; never infer dates from other dates. Use null when unsure and lower the confidence.`;

export function extractionConfigured(): boolean {
  return Boolean(process.env.AI_PROVIDER_KEY);
}

/** Calls the provider on one uploaded file. Returns null when the provider is not configured or the file type cannot be read. */
export async function readDocument(upload: Upload): Promise<Extraction | null> {
  const key = process.env.AI_PROVIDER_KEY;
  if (!key) return null;
  const model = process.env.AI_MODEL || "claude-sonnet-5-5";   // Founder ruling R2, 21 Nov 2026
  const isPdf = upload.content_type === "application/pdf";
  const isImage = ["image/png", "image/jpeg", "image/webp"].includes(upload.content_type);
  if (!isPdf && !isImage) return null;
  const obj = await getObject(vaultConfig(), upload.object_key);
  const data = Buffer.from(obj.body).toString("base64");
  const block = isPdf
    ? { type: "document", source: { type: "base64", media_type: "application/pdf", data } }
    : { type: "image", source: { type: "base64", media_type: upload.content_type, data } };
  // The answer is asked for as the input of a tool, which the provider returns as a ready object: a quoted passage
  // with a quotation mark or a line break in it (common on Arabic certificates) can then no longer break the answer,
  // as it did when the answer was JSON written out as text (production, 24 Nov 2026).
  const field = { type: "object", properties: { value: {}, source: { type: ["string", "null"] }, confidence: { type: "number" } }, required: ["value"] };
  const tool = {
    name: "report_fields",
    description: "Report the fields read from the document.",
    input_schema: {
      type: "object",
      properties: {
        document_kind: { type: "string" },
        fields: { type: "object", properties: Object.fromEntries(EXTRACT_FIELDS.map((f) => [f, field])) },
        notes: { type: ["string", "null"] },
      },
      required: ["fields"],
    },
  };
  // The answer is asked for as a call of the tool. Some models refuse to have the tool forced on them ("tool_choice:
  // type tool and any are not supported for this model"; staging, 28 Nov 2026): for those the tool is offered and the
  // instruction to use it is in the message, and an answer written as text is still read below.
  const ask = (forced: boolean) => fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 4000, system: SYSTEM, tools: [tool], tool_choice: forced ? { type: "tool", name: tool.name } : { type: "auto" },
      messages: [{ role: "user", content: [block, { type: "text", text: `${prompt()}\nReport the result with the report_fields tool, in that same shape. Always call the tool; do not answer in text.` }] }],
    }),
  });
  let res = await ask(true);
  if (res.status === 400) {
    const text = await res.text().catch(() => "");
    if (!/tool_choice/.test(text)) throw new Error(`document reader: 400 ${text.slice(0, 300)}`);
    res = await ask(false);
  }
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`document reader: ${res.status} ${text.slice(0, 300)}`);
  }
  const json = (await res.json()) as { stop_reason?: string; content?: Array<{ type: string; text?: string; input?: unknown }>; usage?: { input_tokens?: number; output_tokens?: number } };
  type Reply = { document_kind?: string; fields?: Record<string, ExtractedField>; notes?: string };
  let parsed = (json.content ?? []).find((c) => c.type === "tool_use")?.input as Reply | undefined;
  if (!parsed || typeof parsed !== "object") {
    // an answer given as text after all: read the JSON in it
    const text = (json.content ?? []).filter((c) => c.type === "text").map((c) => c.text ?? "").join("\n");
    const m = text.match(/\{[\s\S]*\}/);
    if (!m) throw new Error(`document reader: no fields in the reply (stopped: ${json.stop_reason ?? "unknown"})`);
    try { parsed = JSON.parse(m[0]) as Reply; } catch (e) { throw new Error(`document reader: the reply could not be read (${(e as Error).message.slice(0, 120)}; stopped: ${json.stop_reason ?? "unknown"})`); }
  }
  const fields: Extraction["fields"] = {};
  for (const f of EXTRACT_FIELDS) {
    const x = parsed.fields?.[f];
    if (!x || x.value === null || x.value === undefined || x.value === "") continue;
    fields[f] = { value: x.value, source: typeof x.source === "string" ? x.source.slice(0, 300) : null, confidence: Number(x.confidence ?? 0.5) };
  }
  return { fields, model, read_at: new Date().toISOString(), document_kind: parsed.document_kind ?? null, notes: parsed.notes ?? null,
           usage: { input_tokens: json.usage?.input_tokens ?? null, output_tokens: json.usage?.output_tokens ?? null } };
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const STAGES = ["filed", "accepted", "published", "fee_paid", "registered", "renewed"];

/**
 * Merges what was read into the draft: only fields the user has not typed are filled (the user's own entry
 * always wins), and every filled field remembers its source for the review step.
 */
export function mergeExtraction(data: IntakeData, ex: Extraction, fileName: string): { data: IntakeData; sources: Sources; filled: string[] } {
  const d: IntakeData & { _sources?: Sources } = { ...data };
  const sources: Sources = { ...(d._sources ?? {}) };
  const filled: string[] = [];
  const take = (field: string, ok: boolean, assign: () => void) => {
    const f = ex.fields[field as ExtractField];
    if (!f || !ok) return;
    assign(); filled.push(field);
    sources[field] = { file: fileName, quote: f.source, confidence: f.confidence };
  };
  const str = (field: ExtractField) => { const v = ex.fields[field]?.value; return typeof v === "string" ? v.trim() : typeof v === "number" ? String(v) : ""; };
  const date = (field: ExtractField) => { const v = str(field); return DATE.test(v) ? v : ""; };

  if (!d.registry_code) take("registry_code", /^[A-Z]{2}$/.test(str("registry_code").toUpperCase()), () => { d.registry_code = str("registry_code").toUpperCase(); });
  if (!d.stage) take("stage", STAGES.includes(str("stage")), () => { d.stage = str("stage") as IntakeData["stage"]; });
  if (!d.mark_type) take("mark_type", ["word", "device", "combined"].includes(str("mark_type")), () => { d.mark_type = str("mark_type") as IntakeData["mark_type"]; });
  if (!d.mark_text_ar) take("mark_text_ar", !!str("mark_text_ar"), () => { d.mark_text_ar = str("mark_text_ar").slice(0, 200); });
  if (!d.mark_text_en) take("mark_text_en", !!str("mark_text_en"), () => { d.mark_text_en = str("mark_text_en").slice(0, 200); });
  if (!d.classes?.length) {
    const v = ex.fields.classes?.value;
    const arr = Array.isArray(v) ? v.map(Number).filter((n) => Number.isInteger(n) && n >= 1 && n <= 45) : typeof v === "number" ? [v] : [];
    take("classes", arr.length > 0, () => { d.classes = Array.from(new Set(arr)); });
  }
  if (!d.goods) take("goods", !!str("goods"), () => { d.goods = str("goods").slice(0, 4000); });
  if (!d.application_no) take("application_no", !!str("application_no"), () => { d.application_no = str("application_no").slice(0, 60); });
  if (!d.registration_no) take("registration_no", !!str("registration_no"), () => { d.registration_no = str("registration_no").slice(0, 60); });
  for (const f of ["filing_date", "acceptance_date", "publication_date", "opposition_end", "registration_date", "expiry_date", "renewal_date"] as const) {
    if (!d[f]) take(f, !!date(f), () => { d[f] = date(f); });
  }
  d._sources = sources;
  return { data: d, sources, filled };
}
