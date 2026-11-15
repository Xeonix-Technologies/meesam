import { customType, timestamp, uuid } from "drizzle-orm/pg-core";

/** Bilingual text column: {"ar": "...", "en": "..."} — at least one key (Data Architecture 14.2). */
export type I18nText = { ar?: string; en?: string } & Record<string, string | undefined>;

export const citext = customType<{ data: string }>({
  dataType() {
    return "citext";
  },
});

export const bytea = customType<{ data: Buffer; driverData: Buffer }>({
  dataType() {
    return "bytea";
  },
});

/** pgvector column; dimensions fixed per model variant (0002_pgvector.sql). */
export const vector = (dims: number) =>
  customType<{ data: number[]; driverData: string }>({
    dataType() {
      return `vector(${dims})`;
    },
    toDriver(value: number[]) {
      return `[${value.join(",")}]`;
    },
    fromDriver(value: string) {
      return value.slice(1, -1).split(",").map(Number);
    },
  });

/** Columns every table carries (Data Architecture Section 5). */
export const base = {
  id: uuid("id").primaryKey().defaultRandom(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
};

export const timestamps = {
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
};
