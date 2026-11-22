import { sql } from "drizzle-orm";
import { withAccount, withRole } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * What the public Pricing page shows (Founder ruling R10, 21 Nov 2026): the price list in force, read from
 * configuration (core.price_list) through the pricing engine's own functions. No figure is written in code.
 */
export interface PriceStep { years: number; list: number; introductory: number }
export interface PublicPrices {
  name: string | null; currency: string; vatRate: number; steps: PriceStep[]; baseYears: number; floorYears: number;
  introductoryOpen: boolean; introductoryUntil: string | null; filingFee: number | null; filingFeeCredited: boolean; filingFeeRefundable: boolean;
  extraRegistry: number | null; watchOnly: number | null; classAdd: number | null; renewalPrice: number | null; pilotFree: boolean; effectiveFrom: string | null;
}
export async function publicPrices(): Promise<PublicPrices> {
  const r = (await withRole(db(), "meesam_app", (tx) => tx.execute(sql`
    WITH pl AS (SELECT core.fn_price_list_rules() AS rules)
    SELECT pl.rules,
           (SELECT p.effective_from::text FROM core.price_list p WHERE p.rules = pl.rules ORDER BY p.version DESC LIMIT 1) AS effective_from,
           (SELECT jsonb_agg(jsonb_build_object('years', y, 'list', core.fn_scale_price(pl.rules -> 'home_registry', y::smallint), 'introductory', core.fn_scale_price(pl.rules -> 'introductory', y::smallint)) ORDER BY y DESC)
              FROM generate_series((pl.rules #>> '{home_registry,floor_at_years_or_less}')::int, (pl.rules #>> '{home_registry,base_years}')::int) y) AS steps
      FROM pl`))) as unknown as Array<{ rules: Record<string, unknown> & { home_registry: { base_years: number; floor_at_years_or_less: number }; introductory?: { open?: boolean; until?: string | null }; renewal?: { price?: number | null } }; effective_from: string | null; steps: PriceStep[] }>;
  const x = r[0]!;
  const n = (k: string) => (typeof x.rules[k] === "number" ? (x.rules[k] as number) : null);
  return {
    name: typeof x.rules.name === "string" ? x.rules.name : null, currency: String(x.rules.currency ?? "AED"), vatRate: Number(x.rules.vat_rate ?? 0),
    steps: (x.steps ?? []).map((s) => ({ years: Number(s.years), list: Number(s.list), introductory: Number(s.introductory) })),
    baseYears: Number(x.rules.home_registry.base_years), floorYears: Number(x.rules.home_registry.floor_at_years_or_less),
    introductoryOpen: Boolean(x.rules.introductory?.open), introductoryUntil: x.rules.introductory?.until ?? null,
    filingFee: n("filing_fee"), filingFeeCredited: Boolean(x.rules.filing_fee_credited), filingFeeRefundable: Boolean(x.rules.filing_fee_refundable),
    extraRegistry: n("extra_registry"), watchOnly: n("watch_only"), classAdd: n("class_add"), renewalPrice: x.rules.renewal?.price ?? null,
    pilotFree: Boolean(x.rules.pilot_all_free), effectiveFrom: x.effective_from,
  };
}

/** Feedback from a signed-in user (ruling R11; migration 0077). At most 10 an hour per account. */
export async function addFeedback(s: Session, body: string, page: string | null, locale: string): Promise<"ok" | "limit"> {
  return withAccount(db(), { accountId: s.accountId, userId: s.userId }, async (tx) => {
    const ok = (await tx.execute(sql`SELECT platform.fn_rate_hit(${`feedback:${s.accountId}`}, 10, interval '1 hour') AS ok`)) as unknown as Array<{ ok: boolean }>;
    if (ok[0]?.ok === false) return "limit";
    await tx.execute(sql`SELECT platform.fn_feedback_add(${body}, ${page}, ${locale})`);
    return "ok";
  });
}
