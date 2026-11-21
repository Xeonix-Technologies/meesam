import { drizzle } from "drizzle-orm/postgres-js";
import { sql } from "drizzle-orm";
import postgres from "postgres";
import * as schema from "./schema/index.js";

export * from "./schema/index.js";
export { migrate } from "./migrate.js";
export { contentTypeOf, issueKey, shapeProblem } from "./publication-file.js";
export { vaultConfig, probeBucket, putObject, putObjectFile, getObject, getObjectFile, deleteObject, copyObject, presignGet, type VaultConfig } from "./object-store.js";
export type { RegistryProfileRules, TimerRule, Stage, EventType } from "./registry-profile.js";
export type { MigrateOptions } from "./migrate.js";

/**
 * Two connections by rule (CLAUDE.md): the web app uses the pooled URL through PgBouncer,
 * the worker and migrations use the direct URL.
 */
export function createDb(kind: "pooled" | "direct" = "pooled") {
  const url = kind === "pooled" ? process.env.DATABASE_POOL_URL ?? process.env.DATABASE_URL : process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  // PgBouncer in transaction mode: disable prepared statements for the pooled client.
  const client = postgres(url, { prepare: kind === "direct", max: kind === "pooled" ? 10 : 4, onnotice: () => {} });
  return drizzle(client, { schema });
}

export type Db = ReturnType<typeof createDb>;
export type DbRole = "meesam_app" | "meesam_worker" | "meesam_staff" | "meesam_admin" | "meesam_readonly";

/** The session context row-level security reads (Data Architecture Section 6). */
export interface AccountContext {
  accountId: string;
  userId?: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Runs `fn` in one transaction as `meesam_app` with the account context set, so every table's
 * RLS policy applies. Everything the web app does on behalf of a signed-in user goes through here;
 * the application layer is the second line, never the only one (CLAUDE.md rule 2).
 */
export async function withAccount<T>(db: Db, ctx: AccountContext, fn: (tx: Db) => Promise<T>): Promise<T> {
  if (!UUID.test(ctx.accountId)) throw new Error("withAccount: accountId is not a uuid");
  if (ctx.userId !== undefined && !UUID.test(ctx.userId)) throw new Error("withAccount: userId is not a uuid");
  return db.transaction(async (tx) => {
    await tx.execute(sql`SET LOCAL ROLE meesam_app`);
    await tx.execute(sql`SELECT set_config('meesam.account_id', ${ctx.accountId}, true)`);
    await tx.execute(sql`SELECT set_config('meesam.user_id', ${ctx.userId ?? ""}, true)`);
    return fn(tx as unknown as Db);
  });
}

/**
 * Runs `fn` in one transaction as a named role with no account context: staff and system roles
 * bypass RLS by role; `meesam_app` without context sees nothing and may only call the sign-in
 * procedures (SECURITY DEFINER) — that is how sign-up and login run before a session exists.
 */
export async function withRole<T>(db: Db, role: DbRole, fn: (tx: Db) => Promise<T>): Promise<T> {
  return db.transaction(async (tx) => {
    await tx.execute(sql.raw(`SET LOCAL ROLE ${role}`));
    return fn(tx as unknown as Db);
  });
}
