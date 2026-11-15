# Migrations

Plain SQL, written and reviewed by hand (CLAUDE.md: never regenerated destructively). Applied in
file-name order by `packages/db/src/migrate.ts`, which records each file's SHA-256 in
`platform.schema_migration`; an applied file must never change — add a new one.

| File | Content |
|---|---|
| `0001_core.sql` | Schemas, roles, every table of Data Architecture v0.2 Sections 5–10, access view and RLS, lifecycle/timer functions, pricing, procedures, normaliser, job queue, registry seed |
| `0002_pgvector.sql` | Image embedding columns (DINOv3 768-d, SigLIP 2 768-d), HNSW indexes, `core.record_image` — needs pgvector |
| `0003_registry_profiles.sql` | Registry profiles v1 for the 14 registries from the Registry Profiles annex (each clock verified/unverified as the annex states; UAE opens), publication sources per stream, English Nice class headings, timer-engine refinements (reminders relative to due date; profile fallback for historical events) |

Where they run:
- Railway: the `worker` service's pre-deploy command `node dist/migrate.js` (direct `DATABASE_URL`), so a
  deploy that cannot migrate never starts serving.
- Locally / CI: `psql -v ON_ERROR_STOP=1 -f migrations/0001_core.sql` and so on, then `pnpm --filter @meesam/db test:sql`
  (behavioural tests in `tests/sql`, rolled back at the end).

Database roles (`SET LOCAL ROLE` per transaction; see `withAccount` / `withRole` in `src/index.ts`):
`meesam_app` (RLS-bound, needs `meesam.account_id` / `meesam.user_id`), `meesam_worker`, `meesam_staff`,
`meesam_admin`, `meesam_readonly`. Sign-up and account verification run as `meesam_admin`, since no account
context exists yet.

Open rulings carried as `-- RULING NEEDED` in the SQL: cross-border instruction edit rights (read-only
taken), initial risk-band thresholds (0.85 / 0.70 / floor 0.55 as an engineering start).
