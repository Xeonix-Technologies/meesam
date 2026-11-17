import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";
import type { Session } from "./session";

/**
 * Appointments (System Description 4.4 link 1; item 38). Reads go through row-level security; every change
 * goes through the database functions of migration 0010, which check who is calling.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];
/** uuid[] as a PostgreSQL array literal (ids are validated as UUIDs by the caller). */
const arr = (ids: string[]) => `{${ids.join(",")}}`;

export interface AppointmentRow {
  id: string; status: "requested" | "accepted" | "declined" | "ended"; requested_by: "owner" | "agency";
  requested_at: string; accepted_at: string | null; ended_at: string | null; ended_by: "owner" | "agency" | null;
  message: string | null; decline_note: string | null;
  owner_account_id: string; agency_account_id: string; other_name: I18nText; other_country: string | null; other_city: string | null;
  records: Array<{ id: string; mark_text: I18nText | null; registry_code: string; number: string | null }> | null;
  /** records in scope, counted even where the reader cannot open them yet (an agency before it accepts) */
  record_count: number;
}

export async function listAppointments(s: Session): Promise<AppointmentRow[]> {
  return rows<AppointmentRow>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT a.id, a.status, a.requested_by, a.requested_at, a.accepted_at, a.ended_at, a.ended_by, a.message, a.decline_note,
           a.owner_account_id, a.agency_account_id, o.name AS other_name, o.country AS other_country, o.city AS other_city,
           (SELECT jsonb_agg(jsonb_build_object('id', r.id, 'mark_text', r.mark_text, 'registry_code', g.code, 'number', COALESCE(r.registration_no, r.application_no)) ORDER BY r.created_at)
              FROM core.appointment_record ar JOIN core.record r ON r.id = ar.record_id JOIN registry.registry g ON g.id = r.registry_id
             WHERE ar.appointment_id = a.id AND ar.removed_at IS NULL) AS records,
           (SELECT count(*)::int FROM core.appointment_record ar WHERE ar.appointment_id = a.id AND ar.removed_at IS NULL) AS record_count
      FROM core.appointment a
      JOIN core.account o ON o.id = CASE WHEN a.owner_account_id = ${s.accountId}::uuid THEN a.agency_account_id ELSE a.owner_account_id END
     ORDER BY (a.status = 'requested') DESC, (a.status = 'accepted') DESC, a.requested_at DESC`)));
}

export interface DirectoryAgency { id: string; name: I18nText; country: string; city: string | null; contact: Record<string, string> | null; languages_served: string[] | null }

/** Agencies that chose to be listed, after verification (item 4.2: licence verification before directory listing). */
export async function listDirectory(s: Session): Promise<DirectoryAgency[]> {
  return rows<DirectoryAgency>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT id, name, country, city, contact, languages_served FROM core.account
     WHERE directory_listed AND verified_at IS NOT NULL AND kind = 'agency_office' AND id <> ${s.accountId}::uuid ORDER BY country, name ->> 'en'`)));
}

export const requestAppointment = (s: Session, otherAccountId: string, recordIds: string[], message: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_appointment_request(${otherAccountId}::uuid, ${arr(recordIds)}::uuid[], ${message || null})`));
export const respondAppointment = (s: Session, id: string, accept: boolean, recordIds: string[], note: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_appointment_respond(${id}::uuid, ${accept}, ${arr(recordIds)}::uuid[], ${note || null})`));
export const endAppointment = (s: Session, id: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_appointment_end(${id}::uuid)`));
export const setAppointmentRecords = (s: Session, id: string, recordIds: string[]) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_appointment_set_records(${id}::uuid, ${arr(recordIds)}::uuid[])`));

export async function setDirectoryListed(s: Session, listed: boolean): Promise<void> {
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`UPDATE core.account SET directory_listed = ${listed} WHERE id = ${s.accountId}::uuid`));
}
export async function directoryListed(s: Session): Promise<boolean> {
  return Boolean(rows<{ directory_listed: boolean }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT directory_listed FROM core.account WHERE id = ${s.accountId}::uuid`)))[0]?.directory_listed);
}
