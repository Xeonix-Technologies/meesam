# Infrastructure (Railway)

Project `meesam`, workspace Xeonix Technologies, region Southeast Asia (Singapore).
Environments: `staging` (branch `develop`) and `production` (branch `main`). Service names are unique
per project, so the production twin of a service carries a `-prod` suffix (or the staging one `-staging`).

| Service (staging / production) | Source | Railway settings |
|---|---|---|
| `web` / `web-prod` | this repo, root `/`, `RAILWAY_DOCKERFILE_PATH=apps/web/Dockerfile` | public domain; **variable `PORT=3000` and domain target port 3000**; healthcheck `/api/health`; watch `apps/web/**`, `packages/**` |
| `worker` / `worker-prod` | this repo, `RAILWAY_DOCKERFILE_PATH=apps/worker/Dockerfile` | private only; healthcheck `/health`; **pre-deploy command `node dist/migrate.js`** (runs the SQL migrations before the new version serves) |
| `embeddings` / `embeddings-prod` | this repo, `RAILWAY_DOCKERFILE_PATH=apps/embeddings/Dockerfile` | private only; healthcheck `/health`; memory ≥ 4 GB once models load |
| `Postgres-staging` / `Postgres` | template "Postgres 18 + pgvector" | private only; backups daily + weekly (+ monthly); PITR on in production (template start command removed) |
| `meesam-vault-staging`, `meesam-publications-staging` / `meesam-vault-prod`, `meesam-publications-prod` | Railway buckets (S3-compatible, Tigris, region `auto`) | credentials referenced by variable |

Variable references (per environment; `<pg>` is `Postgres-staging` on staging and `Postgres` on production):

```
DATABASE_URL        = ${{<pg>.DATABASE_URL}}             # worker, migrations: direct connection
DATABASE_POOL_URL   = ${{<pg>.DATABASE_URL}}             # web: pooled URL once PgBouncer is added; until then the direct one
VAULT_BUCKET        = ${{meesam-vault-<env>.BUCKET}}
VAULT_ENDPOINT      = ${{meesam-vault-<env>.ENDPOINT}}
VAULT_ACCESS_KEY_ID = ${{meesam-vault-<env>.ACCESS_KEY_ID}}
VAULT_SECRET_ACCESS_KEY = ${{meesam-vault-<env>.SECRET_ACCESS_KEY}}
PUBLICATIONS_*      = same pattern on meesam-publications-<env>
EMBEDDINGS_URL      = http://${{embeddings.RAILWAY_PRIVATE_DOMAIN}}:8000   # embeddings-prod on production
PORT                = 3000 (web) · 8080 (worker) · 8000 (embeddings)
```

Shared variables (Project Settings → Shared Variables): `APP_URL` (`https://staging.meesam.ae` / `https://meesam.ae`),
`DEFAULT_LOCALE`, `SUPPORTED_LOCALES`, `INVOICE_ISSUER`, `EMAIL_FROM` (`Meesam <no-reply@meesam.ae>`), `EMAIL_STREAM` (`outbound`),
and sealed `EMAIL_PROVIDER_KEY` (Postmark server token), `AI_PROVIDER_KEY` (Anthropic API key for the document reader; optional `AI_MODEL`). The `web` service needs `DATABASE_POOL_URL`,
`APP_URL`, `EMAIL_FROM` and `EMAIL_PROVIDER_KEY` for sign-up mail to go out (the `worker` service needs the same three for deadline reminder e-mails; without the key the reminders stay queued), and the four `VAULT_*` bucket references for document upload.

Watch fetcher (worker, and web for issues added by hand under the temporary ruling of 19 Nov 2026): the `worker` and `web` services need the four `PUBLICATIONS_*` bucket references (`PUBLICATIONS_BUCKET`,
`PUBLICATIONS_ENDPOINT`, `PUBLICATIONS_ACCESS_KEY_ID`, `PUBLICATIONS_SECRET_ACCESS_KEY`, same pattern as `VAULT_*` on
`meesam-publications-<env>`). Without them the fetcher does not poll and marks nothing failed; it starts by itself once
they are set. Optional: `WATCH_FETCH_EVERY_MS` (default 2 minutes; each source carries its own poll time). The worker
needs open egress to the registries' sites (MoET first).

Database roles: the Railway credential is used only to connect; every transaction switches to one of
`meesam_app` (RLS-bound), `meesam_worker`, `meesam_staff`, `meesam_admin`, `meesam_readonly`
(see `packages/db/migrations/README.md`).

Edge: Cloudflare in front of `web` (apex and `www` proxied, `staging` DNS-only), WAF managed ruleset,
rate limit on `/api/auth`, Bot Fight Mode, TLS 1.2 minimum, Always Use HTTPS; `meesam.ai` redirects to `meesam.ae`.
Mail: human mailboxes on InMotion (`info@`, `support@`), system mail through Postmark (DKIM + Return-Path verified).

Portability rule: nothing above is Railway-specific in code; moving to another host is a redeploy of the
same Dockerfiles with the same variable names.

Staff: `SYSTEM_ADMIN_EMAILS` (comma-separated, shared to `web`) names the address of the first System Administrator of an
environment. Staff use a separate staff login (never an owner or agency login): on the login page ask for a password
reset for that address; the invitation to choose a password goes to that mailbox, and two-step sign-in applies from
the first login. Further staff are invited inside System Admin → Staff.

Backup copy (Founder ruling 21 Nov 2026, R15): a nightly copy of the database goes to Cloudflare R2 in the EU jurisdiction, a different company and region from Railway Singapore. The `worker` service takes four variables, entered by the Founder in Railway and never committed: `BACKUP_BUCKET` (`meesam-backup-staging` / `meesam-backup-prod`), `BACKUP_ENDPOINT` (`https://<account id>.eu.r2.cloudflarestorage.com`), `BACKUP_ACCESS_KEY_ID`, `BACKUP_SECRET_ACCESS_KEY` (an R2 token with Object Read & Write on that one bucket). The backup job itself is plan item A7 and is not built yet.
