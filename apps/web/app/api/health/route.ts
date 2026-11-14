export const dynamic = "force-dynamic";

/** Railway healthcheck target. Kept dependency-free so a failed DB never blocks a rollout check. */
export function GET() {
  return Response.json({
    status: "ok",
    service: "web",
    version: process.env.RAILWAY_GIT_COMMIT_SHA?.slice(0, 7) ?? "local",
    environment: process.env.RAILWAY_ENVIRONMENT_NAME ?? process.env.NODE_ENV ?? "development",
    time: new Date().toISOString(),
  });
}
