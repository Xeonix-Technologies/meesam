import type { RegistryProfileRules } from "@meesam/db";

/**
 * Advisory consistency checks (System Description 4.7 step 7, Ruled 10 Nov 2026): they warn,
 * never block saving. Each warning names the field it concerns; the user fixes the field or
 * confirms it with a note, and both are kept with the record.
 */
export type IntakeStage = "filed" | "accepted" | "published" | "fee_paid" | "registered" | "renewed";
export const INTAKE_STAGES: IntakeStage[] = ["filed", "accepted", "published", "fee_paid", "registered", "renewed"];
const STAGE_RANK: Record<IntakeStage, number> = { filed: 1, accepted: 2, published: 3, fee_paid: 4, registered: 5, renewed: 6 };

export interface IntakeData {
  manager?: "self" | "agency";
  agency_account_id?: string;
  registry_code?: string;
  stage?: IntakeStage;
  mark_type?: "word" | "device" | "combined";
  mark_text_ar?: string;
  mark_text_en?: string;
  classes?: number[];
  goods?: string;
  application_no?: string;
  filing_date?: string;
  acceptance_date?: string;
  publication_date?: string;
  opposition_end?: string;
  registration_no?: string;
  registration_date?: string;
  expiry_date?: string;
  renewal_date?: string;
}

export interface Warning {
  code: string;
  field: string;
  params?: Record<string, string | number>;
  confirmed_note?: string;
  confirmed_at?: string;
}

const d = (s?: string) => (s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? new Date(`${s}T00:00:00Z`) : null);
const iso = (x: Date) => x.toISOString().slice(0, 10);
const addMonths = (x: Date, m: number) => new Date(Date.UTC(x.getUTCFullYear(), x.getUTCMonth() + m, x.getUTCDate()));
const addDays = (x: Date, n: number) => new Date(x.getTime() + n * 86400000);

export function reachedAtLeast(stage: IntakeStage | undefined, s: IntakeStage): boolean {
  return !!stage && STAGE_RANK[stage] >= STAGE_RANK[s];
}

export function runChecks(data: IntakeData, rules: RegistryProfileRules | null, today = new Date()): Warning[] {
  const w: Warning[] = [];
  const filing = d(data.filing_date);
  const acceptance = d(data.acceptance_date);
  const publication = d(data.publication_date);
  const oppositionEnd = d(data.opposition_end);
  const registration = d(data.registration_date);
  const expiry = d(data.expiry_date);
  const renewal = d(data.renewal_date);
  const stage = data.stage;

  // order of dates
  for (const [label, later] of [["acceptance_date", acceptance], ["publication_date", publication], ["registration_date", registration]] as const) {
    if (filing && later && filing > later) w.push({ code: "filing_after_later", field: "filing_date", params: { later: label } });
  }
  if (acceptance && publication && acceptance > publication) w.push({ code: "acceptance_after_publication", field: "acceptance_date" });
  if (publication && registration && publication > registration) w.push({ code: "publication_after_registration", field: "publication_date" });
  if (registration && renewal && registration > renewal) w.push({ code: "registration_after_renewal", field: "renewal_date" });

  // registration before the opposition window closed
  const oppose = rules?.timers?.oppose;
  let windowEnd: Date | null = oppositionEnd;
  if (!windowEnd && publication && oppose && oppose.verified !== false) {
    if (oppose.days) windowEnd = addDays(publication, oppose.days);
    else if (oppose.months) windowEnd = addMonths(publication, oppose.months);
  }
  if (registration && windowEnd && registration < windowEnd) w.push({ code: "registration_before_opposition_end", field: "registration_date", params: { window_end: iso(windowEnd) } });

  // expiry versus term
  if (expiry && rules?.term) {
    const base = rules.term.from === "registration_date" ? registration : filing;
    if (base) {
      const expected = addMonths(base, rules.term.years * 12);
      if (iso(expected) !== iso(expiry) && !renewal) w.push({ code: "expiry_mismatch", field: "expiry_date", params: { expected: iso(expected), years: rules.term.years } });
    }
  }

  // future dates for a stage already reached
  for (const [field, value] of [["filing_date", filing], ["acceptance_date", acceptance], ["publication_date", publication], ["registration_date", registration], ["renewal_date", renewal]] as const) {
    if (value && value > today) w.push({ code: "future_date", field });
  }

  // classes
  for (const c of data.classes ?? []) if (!(c >= 1 && c <= 45)) w.push({ code: "class_out_of_range", field: "classes", params: { class: c } });
  if (!data.classes?.length) w.push({ code: "no_class", field: "classes" });

  // minimum data for the stage reached
  if (reachedAtLeast(stage, "filed") && !data.application_no) w.push({ code: "missing_for_stage", field: "application_no" });
  if (reachedAtLeast(stage, "filed") && !filing) w.push({ code: "missing_for_stage", field: "filing_date" });
  if (reachedAtLeast(stage, "published") && !publication) w.push({ code: "missing_for_stage", field: "publication_date" });
  if (reachedAtLeast(stage, "registered") && !data.registration_no) w.push({ code: "missing_for_stage", field: "registration_no" });
  if (reachedAtLeast(stage, "registered") && !registration) w.push({ code: "missing_for_stage", field: "registration_date" });
  if (reachedAtLeast(stage, "registered") && !expiry) w.push({ code: "missing_for_stage", field: "expiry_date" });

  // number format when the profile states one
  const pattern = (rules as { filing?: { application_no_pattern?: string } } | null)?.filing?.application_no_pattern;
  if (pattern && data.application_no && !new RegExp(pattern).test(data.application_no)) w.push({ code: "number_format", field: "application_no" });

  return w;
}
