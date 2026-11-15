import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "@/lib/db";
import { consumeToken, localeOf, redirectTo, text } from "@/lib/auth";
import { hashPassword, MIN_PASSWORD_LENGTH } from "@/lib/password";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const form = await req.formData();
  const locale = localeOf(form);
  const token = text(form, "token", 200);
  const password = String(form.get("password") ?? "");
  const password2 = String(form.get("password2") ?? "");
  const back = `/${locale}/reset-password`;
  if (password.length < MIN_PASSWORD_LENGTH) return redirectTo(req, back, { token, error: "password" });
  if (password !== password2) return redirectTo(req, back, { token, error: "passwordMatch" });
  const userId = await consumeToken(token, "password_reset");
  if (!userId) return redirectTo(req, back, { error: "bad" });
  const hash = await hashPassword(password);
  await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT core.sp_set_password(${userId}::uuid, ${hash})`));
  return redirectTo(req, `/${locale}/login`, { reset: "1" });
}
