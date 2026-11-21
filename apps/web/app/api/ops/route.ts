import { NextResponse } from "next/server";
import { isLocale } from "@meesam/i18n";
import { go } from "@/lib/guard";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { closeIncident, confirmReuse, pauseSource, pollSourceNow, setManual, setReuse } from "@/lib/ops";

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
  const back = action === "close" ? `/${locale}/ops/incidents` : action === "reuse_set" ? `/${locale}/ops/quality` : `/${locale}/ops`;
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
    if (action === "manual_off") { await setManual(session, id, false, ""); return go(req, back, { saved: "manualOff" }); }
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
