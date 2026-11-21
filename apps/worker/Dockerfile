# Build context = repository root (RAILWAY_DOCKERFILE_PATH=apps/worker/Dockerfile).
FROM node:22-bookworm-slim AS base
ENV PNPM_HOME=/pnpm PATH=/pnpm:$PATH
RUN corepack enable && corepack prepare pnpm@10.28.0 --activate
WORKDIR /repo

FROM base AS build
COPY pnpm-lock.yaml* pnpm-workspace.yaml package.json .npmrc tsconfig.base.json ./
COPY apps/worker/package.json apps/worker/
COPY packages/db/package.json packages/db/
COPY packages/i18n/package.json packages/i18n/
RUN if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile --filter @meesam/worker...; \
    else pnpm install --filter @meesam/worker...; fi
COPY packages ./packages
COPY apps/worker ./apps/worker
# esbuild bundles the workspace packages' TypeScript into dist/; npm packages stay external
RUN pnpm --filter @meesam/worker build && pnpm --filter @meesam/worker deploy --legacy --prod /out

FROM node:22-bookworm-slim AS runner
ENV NODE_ENV=production PORT=8080 MIGRATIONS_DIR=/app/migrations
WORKDIR /app
# PostgreSQL 18 client tools (pg_dump, pg_restore, psql) for the nightly second copy of the database; the
# version must not be older than the server's, so it comes from the PostgreSQL project's own repository.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends postgresql-client-18 \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
RUN groupadd -r app && useradd -r -g app app
COPY --from=build --chown=app:app /out ./
COPY --from=build --chown=app:app /repo/packages/db/migrations ./migrations
USER app
EXPOSE 8080
# Pre-deploy command on Railway: node dist/migrate.js
CMD ["node", "dist/main.js"]
