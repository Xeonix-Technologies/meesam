import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/** The signed-in user's own notification preferences (System Description 4.11; migration 0037). Critical reminders are not a preference. */
export interface NotifyPrefs { important_digest: boolean; routine_digest: boolean }
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });

export async function getNotifyPrefs(s: Session): Promise<NotifyPrefs> {
  const r = (await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT important_digest, routine_digest FROM core.fn_notify_pref()`))) as unknown as NotifyPrefs[];
  return { important_digest: Boolean(r[0]?.important_digest), routine_digest: r[0]?.routine_digest !== false };
}
export const setNotifyPrefs = (s: Session, p: NotifyPrefs) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_notify_pref_set(${p.important_digest}, ${p.routine_digest})`));
