import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { closeIncident, confirmReuse, pauseSource, pollSourceNow, READ_LANGS, READ_MODELS, requestReadRun, requestReadTest, setManual, setReuse, setShown, stopReadRun } from "@/lib/ops";

export const runtime = "nodejs";

/**
 * Operations Console actions of the watch operations lead: pause or resume a fetcher, ask for a poll now, confirm
 * re-use (which switches a fetcher on), close an incident. The database checks the role again and audits each one. There is no action that takes a file.
 */
export async function POST(req: Request) {
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const session = await getSession();
  if (!session) return go(req, `/${locale}/login`);
  if (!(await staffRoles(session)).includes("watch_lead")) return new NextResponse(null, { status: 404 });
  const action = String(form.get("action") ?? "");
  const id = String(form.get("id") ?? "");
  const note = String(form.get("note") ?? "").trim().slice(0, 500);
  const back = action === "close" ? `/${locale}/ops/incidents` : action === "reuse_set" ? `/${locale}/ops/quality` : action === "read_test" || action === "read_run" || action === "read_stop" ? `/${locale}/ops/reading` : `/${locale}/ops`;
  if (!/^[0-9a-f-]{36}$/.test(id)) return go(req, back, { error: "generic" });
  try {
    if (action === "pause") { await pauseSource(session, id, true, note); return go(req, back, { saved: "paused" }); }
    if (action === "resume") { await pauseSource(session, id, false, ""); return go(req, back, { saved: "resumed" }); }
    if (action === "poll") { await pollSourceNow(session, id); return go(req, back, { saved: "poll" }); }
    if (action === "reuse") {
      // switching a fetcher on is a decision with a stated basis (the re-use gate, MSM-PRD-02 Section 4)
      if (!note) return go(req, back, { error: "basis" });
      await confirmReuse(session, id, note.slice(0, 300));
      return go(req, back, { saved: "reuse" });
    }
    if (action === "manual_on") {
      // temporary ruling of 19 Nov 2026: a source whose site refuses the fetcher may be collected by hand, with the reason stated
      if (!note) return go(req, back, { error: "reason" });
      await setManual(session, id, true, note.slice(0, 300));
      return go(req, back, { saved: "manualOn" });
    }
    if (action === "show_on") {
      // Founder, 26 Nov 2026: a registry's bulletins may be shown to signed-in accounts, with the basis stated
      if (!note) return go(req, back, { error: "basis" });
      await setShown(session, id, true, note.slice(0, 300));
      return go(req, back, { saved: "shownOn" });
    }
    if (action === "show_off") { await setShown(session, id, false, ""); return go(req, back, { saved: "shownOff" }); }
    if (action === "manual_off") { await setManual(session, id, false, ""); return go(req, back, { saved: "manualOff" }); }
    if (action === "read_test") {
      // plan item A1, first step: a few pages of a stored issue through the AI reader; nothing is loaded from it
      const model = String(form.get("model") ?? "");
      // an empty first page means "find where the entries start" (migration 0065)
      const firstRaw = String(form.get("first_page") ?? "").trim();
      const first = firstRaw === "" ? 0 : Number(firstRaw);
      const pages = Number(form.get("pages") ?? 2);
      if (!(READ_MODELS as readonly string[]).includes(model) || !Number.isInteger(first) || first < 0 || !Number.isInteger(pages) || pages < 1 || pages > 5) return go(req, back, { error: "readInput" });
      const lang = String(form.get("translate_to") ?? "");
      if (lang && !(READ_LANGS as readonly string[]).includes(lang)) return go(req, back, { error: "readInput" });
      try { await requestReadTest(session, id, first, pages, model, lang || null); }
      catch (e) {
        const code = (e as { cause?: { code?: string } }).cause?.code;
        if (code === "54000") return go(req, back, { error: "readMany" });
        if (code === "42501") return go(req, back, { error: "readReuse" });
        throw e;
      }
      return go(req, back, { saved: "readAsked" });
    }
    if (action === "read_run") {
      // plan item A1: a whole stored issue through the AI reader; every mark is stored waiting for verification
      const model = String(form.get("model") ?? "");
      if (!(READ_MODELS as readonly string[]).includes(model)) return go(req, back, { error: "readInput" });
      // optional: some pages only (migration 0075)
      const pf = String(form.get("from_page") ?? "").trim(), pt = String(form.get("to_page") ?? "").trim();
      if ((pf === "") !== (pt === "") || (pf && !/^\d{1,5}$/.test(pf)) || (pt && !/^\d{1,5}$/.test(pt))) return go(req, back, { error: "runRange" });
      try { await requestReadRun(session, id, model, pf ? Number(pf) : null, pt ? Number(pt) : null); }
      catch (e) {
        const code = (e as { cause?: { code?: string } }).cause?.code;
        const known: Record<string, string> = { "54000": "runMany", "42501": "readReuse", "55000": "runLayout", "22004": "runDate", "23505": "runActive", "22023": "runRange" };
        if (code && known[code]) return go(req, back, { error: known[code]! });
        throw e;
      }
      return go(req, back, { saved: "runAsked" });
    }
    if (action === "read_stop") { await stopReadRun(session, id); return go(req, back, { saved: "runStopped" }); }
    if (action === "reuse_set") {
      // the re-use register (ruling R8, 21 Nov 2026): yes, no, or not yet read for each use; "no" to storing pauses the registry's sources
      const tri = (k: string) => { const v = String(form.get(k) ?? ""); return v === "yes" ? true : v === "no" ? false : null; };
      const readOn = String(form.get("read_on") ?? "");
      const url = String(form.get("terms_url") ?? "").trim();
      if (url && !/^https?:\/\//i.test(url)) return go(req, back, { error: "link" });
      if (readOn && (!/^\d{4}-\d{2}-\d{2}$/.test(readOn) || readOn > new Date().toISOString().slice(0, 10))) return go(req, back, { error: "readOn" });
      await setReuse(session, id, { terms: String(form.get("terms") ?? "").trim().slice(0, 1000), url: url.slice(0, 500), readOn: readOn || null,
        store: tri("store"), show: tri("show"), derive: tri("derive"), train: tri("train"), contact: tri("contact"), note });
      return go(req, back, { saved: "reuseSet" });
    }
    if (action === "close") { await closeIncident(session, id, note); return go(req, back, { saved: "closed" }); }
  } catch (e) {
    const err = e as Error & { cause?: { message?: string } };
    console.error(JSON.stringify({ level: "error", at: "ops", action, message: err.cause?.message ?? err.message }));
  }
  return go(req, back, { error: "generic" });
}
