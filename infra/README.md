# Infrastructure (Railway)

Project `meesam`, workspace Xeonix Technologies, region Southeast Asia (Singapore).
Environments: `staging` (branch `develop`) and `production` (branch `main`).

| Service | Source | Railway settings |
|---|---|---|
| `web` | this repo, root `/`, `RAILWAY_DOCKERFILE_PATH=apps/web/Dockerfile` | public domain; healthcheck `/api/health`; watch `apps/web/**`, `packages/**` |
| `worker` | this repo, `RAILWAY_DOCKERFILE_PATH=apps/worker/Dockerfile` | private only; healthcheck `/health` |
| `embeddings` | this repo, `RAILWAY_DOCKERFILE_PATH=apps/embeddings/Dockerfile` | private only; healthcheck `/health`; memory ≥ 4 GB once models load |
| `Postgres` / `Postgres-staging` | template "Postgres 18 + pgvector" | private only; backups daily+weekly(+monthly); PITR on in production |
| `PgBouncer` | template | pooled URL for `web` |
| `meesam-vault-*`, `meesam-publications-*` | Railway buckets (S3-compatible) | credentials referenced by variable |

Variable references (per environment):

```
DATABASE_URL        = ${{Postgres.DATABASE_URL}}            # staging: ${{Postgres-staging.DATABASE_URL}}
DATABASE_POOL_URL   = ${{PgBouncer.DATABASE_POOL_URL}}       # or the pooled URL the template exposes
VAULT_BUCKET        = ${{meesam-vault-prod.BUCKET}}          # staging: meesam-vault-staging
VAULT_ENDPOINT      = ${{meesam-vault-prod.ENDPOINT}}
VAULT_ACCESS_KEY_ID = ${{meesam-vault-prod.ACCESS_KEY_ID}}
VAULT_SECRET_ACCESS_KEY = ${{meesam-vault-prod.SECRET_ACCESS_KEY}}
PUBLICATIONS_*      = same pattern on meesam-publications-*
EMBEDDINGS_URL      = http://${{embeddings.RAILWAY_PRIVATE_DOMAIN}}:8000
```

Shared variables (set in Project Settings → Shared Variables): `APP_URL`, `DEFAULT_LOCALE`, `SUPPORTED_LOCALES`,
`INVOICE_ISSUER`, `EMAIL_FROM`, and sealed `AUTH_SECRET`, `EMAIL_PROVIDER_KEY`, `AI_PROVIDER_KEY`.

Portability rule: nothing above is Railway-specific in code; moving to another host is a redeploy of the
same Dockerfiles with the same variable names.
