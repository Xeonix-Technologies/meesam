import { sql } from "drizzle-orm";
import { withRole, type Db, type Job } from "@meesam/db";

/**
 * Translation of what a registry published, beside the registry's own text (Founder rulings 21 and 22 Nov 2026;
 * migration 0080). Names are written in the target language's script as they sound, legal-form words and the goods
 * are translated. The mark's own wording is never sent and never translated. The registry's text is never changed:
 * the translation is kept beside the mark, per language, and shown with a notice that the registry's text is the
 * official one.
 */
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
           m.extraction ->> 'goods' AS goods, m.extraction ->> 'image_description' AS image_description, COALESCE(m.extraction -> 't' ? ${lang}, false) AS done
      FROM watch.published_mark m WHERE m.issue_id = ${p.issue_id}::uuid AND m.id = ${p.mark_id}::uuid`))[0];
  if (!m || m.done) return;
  const source: Record<string, string> = {};
  for (const f of FIELDS) if (m[f] && m[f]!.trim()) source[f] = m[f]!.trim().slice(0, 12000);
  const store = (t: Record<string, unknown>) => q(sql`SELECT watch.fn_translation_store(${p.issue_id!}::uuid, ${p.mark_id!}::uuid, ${lang}, ${JSON.stringify(t)}::jsonb)`);
  if (Object.keys(source).length === 0) { await store({}); return; }

  let name = lang;
  try { name = new Intl.DisplayNames(["en"], { type: "language" }).of(lang) ?? lang; } catch { /* keep the code */ }
  const model = process.env.AI_TRANSLATE_MODEL ?? "claude-haiku-5-5";
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
    body: JSON.stringify({
      model, max_tokens: 8000,
      system: "You translate entries of official trademark gazettes. You return one JSON object and nothing else. You never add, drop or soften information.",
      messages: [{ role: "user", content: `Translate the values of this JSON object into ${name}. Keep the same keys.
- A person's or company's name: write it in the script of ${name} as it sounds (or its established form in that language when it clearly has one), and translate the words for the legal form (company, limited, and the like).
- An address or a city: write it in the script of ${name}; keep numbers and codes exactly.
- Goods and services, and descriptions: translate fully and faithfully, keeping the order and the punctuation between items.
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
