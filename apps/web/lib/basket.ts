import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Activation and the basket (Founder ruling 27 Nov 2026; migration 0104). A trademark loaded in bulk is kept and
 * shown but Meesam does not work for it (no reminders, no calendar feed, no watch) until it is activated. The
 * account asks for activation once the mark has its image and a document; the mark goes to the basket, and one
 * checkout activates everything in it. Every rule is the database's; this file only calls it.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T>(r: unknown) => r as unknown as T[];

export interface ActivationCounts { waiting: number; ready: number; in_basket: number }
export async function activationCounts(s: Session): Promise<ActivationCounts> {
  const r = rows<ActivationCounts>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT waiting, ready, in_basket FROM core.fn_activation_counts()`)))[0];
  return { waiting: Number(r?.waiting ?? 0), ready: Number(r?.ready ?? 0), in_basket: Number(r?.in_basket ?? 0) };
}

export interface BasketLine {
  record_id: string; mark_text: I18nText | null; registry_code: string; number: string | null; client: string | null; requested_at: string;
  years_remaining: number | null; list_amount: string | null; amount: string | null; introductory: boolean | null; due: string | null; vat: string | null; total: string | null; vat_inclusive: boolean | null;
}
/** The basket and whether checkout is open: free while the price list says the pilot is free; otherwise payment is not connected yet. */
export async function basket(s: Session): Promise<{ lines: BasketLine[]; free: boolean }> {
  return withAccount(db(), ctx(s), async (tx) => {
    const lines = rows<BasketLine>(await tx.execute(sql`SELECT * FROM core.fn_basket()`));
    const free = Boolean(rows<{ free: boolean }>(await tx.execute(sql`SELECT core.fn_basket_free() AS free`))[0]?.free);
    return { lines, free };
  });
}

/** Puts one record, or (no id) every ready record of the account, in the basket. Returns how many went in. */
export async function requestActivation(s: Session, recordId: string | null): Promise<number> {
  const r = rows<{ n: number }>(await withAccount(db(), ctx(s), (tx) => tx.execute(recordId
    ? sql`SELECT core.fn_activation_request(ARRAY[${recordId}::uuid]) AS n`
    : sql`SELECT core.fn_activation_request() AS n`)))[0];
  return Number(r?.n ?? 0);
}
export async function withdrawActivation(s: Session, recordId: string): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_activation_withdraw(${recordId}::uuid)`));
}
/** Activates everything in the basket. Returns how many were activated. */
export async function checkoutBasket(s: Session): Promise<number> {
  const r = rows<{ n: number }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_basket_checkout() AS n`)))[0];
  return Number(r?.n ?? 0);
}
