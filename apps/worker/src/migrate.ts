import path from "node:path";
import { migrate } from "@meesam/db";

/**
 * Pre-deploy step on Railway (service settings → Deploy → Pre-deploy command: `node dist/migrate.js`).
 * Uses the direct connection string and the SQL files copied into the image at MIGRATIONS_DIR.
 */
const url = process.env.DATABASE_URL;
if (!url) {
  console.error(JSON.stringify({ level: "error", at: "migrate", message: "DATABASE_URL is not set" }));
  process.exit(2);
}
const dir = process.env.MIGRATIONS_DIR ?? path.resolve(process.cwd(), "migrations");

migrate({ url, dir, log: (line) => console.log(JSON.stringify({ level: "info", at: "migrate", message: line })) })
  .then((applied) => {
    console.log(JSON.stringify({ level: "info", at: "migrate.done", applied }));
    process.exit(0);
  })
  .catch((err: unknown) => {
    console.error(JSON.stringify({ level: "error", at: "migrate.failed", message: (err as Error).message }));
    process.exit(1);
  });
