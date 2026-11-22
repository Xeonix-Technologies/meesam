import { sql } from "drizzle-orm";
import { withRole, type Db, type Job } from "@meesam/db";

/**
 * Translation of what a registry published, beside the registry's own text (Founder rulings 21 and 22 Nov 2026;
 * migration 0080). The mark's own wording is never sent and never translated. The registry's text is never changed:
 * the translation is kept beside the mark, per language, and shown with a notice that the registry's text is the
 * official one.
 *
 * Rules, second version (Founder, 22 Nov 2026: "The Arabic translation is not that accurate"; what was wrong were
 * the names and addresses, written in Arabic letters as they sound):
 *  - goods, services and descriptions are translated in full;
 *  - a name or an address is a proper name: it is left as the registry printed it. Only where it is printed in a
 *    script other than Latin and the reader's language is written in Latin letters is it also given in Latin
 *    letters, so that it can be read. A name is never re-written into Arabic or another non-Latin script.
 * Ruled 22 Nov 2026: names are not given in Arabic letters for Arabic readers.
 */
export const RULES = 2;
/** languages written in a script other than Latin: a name is never re-written into these */
const NON_LATIN_TARGETS = new Set(["ar", "fa", "ur", "he", "ru", "uk", "bg", "el", "zh", "ja", "ko", "hi", "th", "ka", "hy"]);
const NAME_FIELDS = new Set(["applicant_name", "applicant_address", "agent_name", "agent_city"]);
/** true when most letters of the text are outside the Latin script */
export const mostlyNonLatin = (text: string): boolean => {
  const letters = text.match(/\p{L}/gu) ?? [];
  if (letters.length === 0) return false;
  const latin = letters.filter((c) => /\p{Script=Latin}/u.test(c)).length;
  return latin * 2 < letters.length;
};
/** how much of a long list of goods is translated */
const GOODS_CHARS = 9000;
type Log = (level: "info" | "error", at: string, extra?: Record<string, unknown>) => void;

const FIELDS = ["applicant_name", "applicant_address", "agent_name", "agent_city", "goods", "image_description"] as const;

export async function runTranslate(conn: Db, job: Job, log: Log): Promise<void> {
  const p = job.payload as { issue_id?: string; mark_id?: string; lang?: string };
  const lang = String(p.lang ?? "");
  if (!/^[a-z]{2}$/.test(lang) || !p.issue_id || !p.mark_id) return;
  const key = process.env.AI_PROVIDER_KEY;
  if (!key) throw new Error("AI_PROVIDER_KEY is not set on the worker service");
  const q = <T>(query: ReturnType<typeof sql>) => withRole(conn, "meesam_worker", async (tx) => (await tx.execute(query)) as unknown as T[]);
  const m = (await q<Record<(typeof FIELDS)[number], string | null> & { done: boolean }>(sql`
    SELECT m.applicant_name, m.extraction ->> 'applicant_address' AS applicant_address, m.agent_name, m.extraction ->> 'agent_city' AS agent_city,
           m.extraction ->> 'goods' AS goods, m.extraction ->> 'image_description' AS image_description, COALESCE(m.extraction -> 't' -> ${lang} ->> 'rules' = ${String(RULES)}, false) AS done
      FROM watch.published_mark m WHERE m.issue_id = ${p.issue_id}::uuid AND m.id = ${p.mark_id}::uuid`))[0];
  if (!m || m.done) return;
  const source: Record<string, string> = {};
  for (const f of FIELDS) {
    const v = m[f]?.trim();
    if (!v) continue;
    // a name or address goes to the translator only to be given in Latin letters to a reader who cannot read its script
    if (NAME_FIELDS.has(f) && (NON_LATIN_TARGETS.has(lang) || !mostlyNonLatin(v))) continue;
    source[f] = v.length > GOODS_CHARS ? `${v.slice(0, GOODS_CHARS)} …` : v;
  }
  const store = (t: Record<string, unknown>) => q(sql`SELECT watch.fn_translation_store(${p.issue_id!}::uuid, ${p.mark_id!}::uuid, ${lang}, ${JSON.stringify({ ...t, rules: RULES })}::jsonb)`);
  if (Object.keys(source).length === 0) { await store({}); return; }

  let name = lang;
  try { name = new Intl.DisplayNames(["en"], { type: "language" }).of(lang) ?? lang; } catch { /* keep the code */ }
  const model = process.env.AI_TRANSLATE_MODEL ?? "claude-haiku-5-5";
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 12000,
      system: "You translate entries of official trademark gazettes. You return one JSON object and nothing else. You never add, drop or soften information.",
      messages: [{ role: "user", content: `Translate the values of this JSON object into ${name}. Keep the same keys.
- Goods and services, and descriptions: translate fully and faithfully, item by item, keeping the order and the punctuation between items. Where an item has an established wording in the Nice Classification in ${name}, use that wording. Never summarise and never leave an item out. A text that ends with " …" was cut: end the translation with " …" too.
- A person's or company's name: give it in Latin letters as it is usually written (its own established form when it clearly has one, otherwise letter by letter), and translate the words for the legal form (company, limited, and the like). Do not translate the name itself.
- An address or a city: give it in Latin letters; keep numbers and codes exactly.
- A value that is already in ${name} is returned unchanged.
Add one more key, "source_language": the two-letter code of the language the text is mostly written in.

${JSON.stringify(source)}` }],
    }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`AI translator: ${res.status} ${text.slice(0, 300)}`);
  const json = JSON.parse(text) as { content?: Array<{ type: string; text?: string }>; usage?: { input_tokens?: number; output_tokens?: number } };
  const out = (json.content ?? []).filter((c) => c.type === "text").map((c) => c.text ?? "").join("");
  const a = out.indexOf("{"), b = out.lastIndexOf("}");
  if (a < 0 || b <= a) throw new Error("the translator's reply was not readable as data");
  const parsed = JSON.parse(out.slice(a, b + 1)) as Record<string, unknown>;
  const t: Record<string, unknown> = { model };
  for (const f of FIELDS) if (typeof parsed[f] === "string" && (parsed[f] as string).trim()) t[f] = (parsed[f] as string).trim().slice(0, 20000);
  if (typeof parsed.source_language === "string" && /^[a-z]{2}$/.test(parsed.source_language)) t.source_language = parsed.source_language;
  // the text was already in the language asked for: nothing to show beside it
  if (t.source_language === lang) for (const f of FIELDS) delete t[f];
  await store(t);
  log("info", "translate.done", { mark: p.mark_id, lang, in: json.usage?.input_tokens, out: json.usage?.output_tokens });
}
