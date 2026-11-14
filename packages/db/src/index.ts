import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";

/**
 * Two connections by rule (CLAUDE.md): the web app uses the pooled URL through PgBouncer,
 * the worker and migrations use the direct URL.
 */
export function createDb(kind: "pooled" | "direct" = "pooled") {
  const url = kind === "pooled" ? process.env.DATABASE_POOL_URL ?? process.env.DATABASE_URL : process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  // PgBouncer in transaction mode: disable prepared statements for the pooled client.
  const client = postgres(url, { prepare: kind === "direct", max: kind === "pooled" ? 10 : 4 });
  return drizzle(client);
}

export type Db = ReturnType<typeof createDb>;
