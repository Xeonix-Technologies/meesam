import { createDb, type Db } from "@meesam/db";

/** One pooled client per server process (DATABASE_POOL_URL; CLAUDE.md). */
const globalForDb = globalThis as unknown as { __meesamDb?: Db };

export function db(): Db {
  if (!globalForDb.__meesamDb) globalForDb.__meesamDb = createDb("pooled");
  return globalForDb.__meesamDb;
}
