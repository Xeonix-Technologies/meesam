import type { Config } from "drizzle-kit";

// Migrations are plain SQL under ./migrations and are reviewed before they run (CLAUDE.md).
export default {
  schema: "./src/schema/index.ts",
  out: "./migrations",
  dialect: "postgresql",
  dbCredentials: { url: process.env.DATABASE_URL ?? "" },
  strict: true,
  verbose: true,
} satisfies Config;
