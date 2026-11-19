import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import { db } from "./db";
import { CONSENT_DOCUMENTS, LEGAL_VERSION } from "@/content/legal.generated";

/**
 * Writes what the person accepted, and which version, at the moment the account or login is created
 * (core.legal_acceptance, migration 0040). `asUser` sets the session context for a login that already exists
 * (an accepted invitation); a brand-new user is accepted by the function within its first hour.
 */
export async function recordConsent(userId: string, context: "sign_up" | "invitation", asUser = false): Promise<void> {
  await withRole(db(), "meesam_app", async (tx) => {
    if (asUser) await tx.execute(sql`SELECT set_config('meesam.user_id', ${userId}, true)`);
    await tx.execute(sql`SELECT core.sp_record_consent(${userId}::uuid, ${sql.raw(`ARRAY[${CONSENT_DOCUMENTS.map((d) => `'${d}'`).join(",")}]`)}::text[], ${LEGAL_VERSION}, ${context})`);
  });
}
