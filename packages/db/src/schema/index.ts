// Drizzle definitions mirror the SQL migrations in ../../migrations (the migrations own the DDL;
// drizzle-kit is used for diff review only, never to generate destructive changes — CLAUDE.md).
// One file per schema: core, registry, watch, platform. The prospect schema is staff-only and
// has no application-side definition on purpose (Data Architecture Section 9).
export * from "./common.js";
export * from "./registry.js";
export * from "./platform.js";
export * from "./core.js";
export * from "./watch.js";
