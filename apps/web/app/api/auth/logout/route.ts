import { localeOf, redirectTo } from "@/lib/auth";
import { destroySession } from "@/lib/session";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  await destroySession();
  return redirectTo(req, form.get("next") === "login" ? `/${localeOf(form)}/login` : `/${localeOf(form)}`);
}
