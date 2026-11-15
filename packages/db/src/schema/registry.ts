import { boolean, char, date, index, integer, jsonb, pgSchema, smallint, text, unique, uuid } from "drizzle-orm/pg-core";
import { base, type I18nText } from "./common.js";
import type { RegistryProfileRules } from "../registry-profile.js";

export const registrySchema = pgSchema("registry");

/** One trademark office; code is WIPO ST.3 (item 22). Registries are never login users. */
export const registry = registrySchema.table("registry", {
  ...base,
  code: text("code").notNull().unique(),
  name: jsonb("name").$type<I18nText>().notNull(),
  country: char("country", { length: 2 }),
  supported: boolean("supported").notNull().default(false),
  launchWave: smallint("launch_wave"),
});

/** A registry's rules as data: calendar, term, timers, reminders, status map (items 25–28, 42, 44). */
export const registryProfile = registrySchema.table(
  "registry_profile",
  {
    ...base,
    registryId: uuid("registry_id")
      .notNull()
      .references(() => registry.id),
    version: integer("version").notNull(),
    effectiveFrom: date("effective_from").notNull(),
    verified: boolean("verified").notNull().default(false),
    rules: jsonb("rules").$type<RegistryProfileRules>().notNull(),
  },
  (t) => [unique().on(t.registryId, t.version), index("registry_profile_registry_id_effective_from_idx").on(t.registryId, t.effectiveFrom)],
);

/** Nice 13th edition classes (item 17). */
export const niceClass = registrySchema.table("nice_class", {
  ...base,
  number: smallint("number").notNull().unique(),
  heading: jsonb("heading").$type<I18nText>().notNull(),
  edition: text("edition").notNull().default("NCL(13-2026)"),
});

export const niceTerm = registrySchema.table(
  "nice_term",
  {
    ...base,
    classId: uuid("class_id")
      .notNull()
      .references(() => niceClass.id),
    term: jsonb("term").$type<I18nText>().notNull(),
    basicNumber: text("basic_number"),
  },
  (t) => [index("nice_term_class_id_idx").on(t.classId)],
);
