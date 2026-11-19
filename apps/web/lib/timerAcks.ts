import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

// ---------------------------------------------------------------- acknowledge and assign (System Description 4.11; migration 0039)

export interface TimerAck { timer_id: string; acknowledged_at: string | null; acknowledged_by: string | null; assigned_user_id: string | null; assigned_to: string | null }
const actx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
/** This account's acknowledgements and assignments on a record's deadlines (each account keeps its own). */
export async function timerAcks(s: Session, recordId: string): Promise<TimerAck[]> {
  return (await withAccount(db(), actx(s), (tx) => tx.execute(sql`
    SELECT k.timer_id, k.acknowledged_at, (SELECT name FROM core.app_user WHERE id = k.acknowledged_by_user_id) AS acknowledged_by,
           k.assigned_user_id, (SELECT name FROM core.app_user WHERE id = k.assigned_user_id) AS assigned_to
      FROM core.timer_ack k WHERE k.record_id = ${recordId}::uuid`))) as unknown as TimerAck[];
}
export const acknowledgeTimer = (s: Session, timerId: string) => withAccount(db(), actx(s), (tx) => tx.execute(sql`SELECT core.fn_timer_acknowledge(${timerId}::uuid)`));
export const assignTimer = (s: Session, timerId: string, userId: string | null) =>
  withAccount(db(), actx(s), (tx) => tx.execute(sql`SELECT core.fn_timer_assign(${timerId}::uuid, ${userId}::uuid)`));
/** The users of this account a deadline can be assigned to. */
export async function assignableUsers(s: Session): Promise<Array<{ id: string; name: string; email: string; locale: string }>> {
  return (await withAccount(db(), actx(s), (tx) => tx.execute(sql`
    SELECT id, name, email::text AS email, locale FROM core.app_user WHERE account_id = ${s.accountId}::uuid AND status = 'active' AND role <> 'viewer' ORDER BY name`))) as unknown as Array<{ id: string; name: string; email: string; locale: string }>;
}
