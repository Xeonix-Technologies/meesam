import type { I18nText } from "./schema/common.js";

/**
 * The shape of registry.registry_profile.rules — the only place a registry's periods, stage names
 * and status wording live (CLAUDE.md rule 4). Values come from the Registry Profiles and Deadlines
 * annex of MSM-PRD-02; nothing here is a default.
 */
export type Stage =
  | "pre_filing"
  | "filing_examination"
  | "acceptance_publication_opposition"
  | "appeals"
  | "registration"
  | "post_registration_recordals"
  | "renewal_grace_expiry"
  | "challenges"
  | "enforcement";

export type EventType =
  | "filed"
  | "formal_ok"
  | "office_action"
  | "response_filed"
  | "accepted"
  | "published"
  | "opposed"
  | "appealed"
  | "registered"
  | "declaration_of_use"
  | "recordal"
  | "renewal_window"
  | "renewed"
  | "expired"
  | "challenged"
  | "enforcement"
  | "cancelled"
  | "refused"
  | "withdrawn";

/** One clock. Exactly one of days / months / months_before_expiry / months_after_expiry / at_expiry. */
export interface TimerRule {
  start_event: EventType;
  days?: number;
  months?: number;
  months_before_expiry?: number;
  months_after_expiry?: number;
  at_expiry?: true;
  /** A clock with verified=false (or absent, when the profile is unverified) creates a timer awaiting the user's entry — no default. */
  verified?: boolean;
  extension?: { days?: number; months?: number; note?: I18nText } | null;
  consequence?: I18nText;
}

export interface RegistryProfileRules {
  calendar: {
    /** IANA zone; a day ends 23:59 here (item 44). */
    timezone: string;
    /** 0 = Sunday … 6 = Saturday */
    weekend: number[];
    /** ISO dates */
    holidays: string[];
  };
  term?: { years: number; from: "filing_date" | "registration_date" };
  timers: Record<string, TimerRule>;
  /** months before expiry at which reminder timers are created, keyed by the statutory clock they derive from */
  reminders?: Record<string, number[]>;
  status_map?: Partial<Record<EventType, { stage: Stage; terminal?: boolean; label?: I18nText }>>;
  human_review_waived?: boolean;
  foreign_applicant_route?: I18nText;
  fee_basis?: "per_class" | "per_mark";
  publication_streams?: string[];
}
