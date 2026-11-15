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
RUN groupadd -r app && useradd -r -g app app
COPY --from=build --chown=app:app /out ./
COPY --from=build --chown=app:app /repo/packages/db/migrations ./migrations
USER app
EXPOSE 8080
# Pre-deploy command on Railway: node dist/migrate.js
CMD ["node", "dist/main.js"]
