import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import postgres from "postgres";

/**
 * Applies the plain SQL files in packages/db/migrations in name order (CLAUDE.md: reviewed SQL,
 * never regenerated destructively). Each file is recorded in platform.schema_migration with its
 * SHA-256; an applied file whose content later differs fails the run — add a new file instead.
 * Runs on the direct connection (DATABASE_URL), as the worker's pre-deploy step.
 */
export interface MigrateOptions {
  url: string;
  dir: string;
  log?: (line: string) => void;
}

export async function migrate({ url, dir, log = () => {} }: MigrateOptions): Promise<string[]> {
  const sql = postgres(url, { max: 1, onnotice: () => {} });
  const applied: string[] = [];
  try {
    await sql`CREATE SCHEMA IF NOT EXISTS platform`;
    await sql`CREATE TABLE IF NOT EXISTS platform.schema_migration (
      name text PRIMARY KEY,
      sha256 text NOT NULL,
      applied_at timestamptz NOT NULL DEFAULT now()
    )`;
    // One migrator at a time per database.
    await sql`SELECT pg_advisory_lock(726501)`;
    try {
      const files = (await readdir(dir)).filter((f) => /^\d{4}_.+\.sql$/.test(f)).sort();
      const rows = await sql<{ name: string; sha256: string }[]>`SELECT name, sha256 FROM platform.schema_migration`;
      const done = new Map(rows.map((r) => [r.name, r.sha256]));
      for (const file of files) {
        const content = await readFile(path.join(dir, file), "utf8");
        const sha = createHash("sha256").update(content).digest("hex");
        const previous = done.get(file);
        if (previous) {
          if (previous !== sha) throw new Error(`migration ${file} was modified after it was applied (sha ${previous} → ${sha})`);
          continue;
        }
        log(`applying ${file}`);
        // Files carry their own BEGIN/COMMIT; simple-query protocol allows several statements.
        await sql.unsafe(content);
        await sql`INSERT INTO platform.schema_migration (name, sha256) VALUES (${file}, ${sha})`;
        applied.push(file);
      }
    } finally {
      await sql`SELECT pg_advisory_unlock(726501)`;
    }
  } finally {
    await sql.end();
  }
  return applied;
}
