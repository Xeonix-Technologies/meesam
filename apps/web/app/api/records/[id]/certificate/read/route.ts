import { isLocale } from "@meesam/i18n";
import { go, requireVerified } from "@/lib/guard";
import { readCertificates } from "@/lib/certificate";

export const runtime = "nodejs";

/** Reads the record's certificates that have not been read yet (migration 0106): asked for from the activation note when a reading did not happen at upload. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const form = await req.formData();
  const localeRaw = String(form.get("locale") ?? "");
  const locale = isLocale(localeRaw) ? localeRaw : "en";
  const auth = await requireVerified(req, locale);
  if ("response" in auth) return auth.response;
  const back = `/${locale}/records/${id}`;
  const run = await readCertificates(auth.session, id);
  if (!run.configured) return go(req, back, { tab: "documents", error: "readerOff" });
  if (run.failed && !run.read && !run.unclear) return go(req, back, { tab: "documents", error: "readerFailed" });
  return go(req, back, { tab: "documents", saved: "1" });
}
