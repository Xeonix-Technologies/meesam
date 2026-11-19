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

export async function requestAppointment(s: Session, otherAccountId: string, recordIds: string[], message: string): Promise<string> {
  const r = rows<{ id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_appointment_request(${otherAccountId}::uuid, ${arr(recordIds)}::uuid[], ${message || null}) AS id`)));
  return r[0]!.id;
}
/** The other side's users who are told by e-mail (active, not Viewer). */
export async function appointmentRecipients(s: Session, id: string): Promise<Array<{ email: string; name: string; locale: string; account_name: I18nText; account_id: string }>> {
  return rows(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT r.email, r.name, r.locale, r.account_name,
           (SELECT CASE WHEN a.owner_account_id = ${s.accountId}::uuid THEN a.agency_account_id ELSE a.owner_account_id END FROM core.appointment a WHERE a.id = ${id}::uuid) AS account_id
      FROM core.fn_appointment_recipients(${id}::uuid) r`)));
}
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

/** Requests waiting for this account's answer (sent by the other side); shown on the side navigation and the dashboard. */
export async function pendingAppointmentCount(s: Session): Promise<number> {
  return Number(rows<{ n: number }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT count(*)::int AS n FROM core.appointment WHERE status = 'requested'
       AND requested_by <> (CASE WHEN agency_account_id = ${s.accountId}::uuid THEN 'agency' ELSE 'owner' END)::core.party_side`)))[0]?.n ?? 0);
}

/** An agency invites an owner by e-mail (migration 0026): an existing owner gets a request, a new address a sign-up link. */
export async function inviteOwner(s: Session, email: string, message: string, notifyOwner = true): Promise<{ outcome: "request" | "invited"; appointment_id: string | null; invite_id: string }> {
  return rows<{ outcome: "request" | "invited"; appointment_id: string | null; invite_id: string }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT outcome, appointment_id, invite_id FROM core.fn_owner_invite(${email}::citext, ${message || null}::text, ${notifyOwner}::boolean)`)))[0]!;
}
export interface OwnerInviteRow { id: string; email: string; created_at: string }
/** Invitations of this office still waiting for the owner to create an account. */
export async function listOwnerInvites(s: Session): Promise<OwnerInviteRow[]> {
  return rows<OwnerInviteRow>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT id, email::text AS email, created_at FROM core.owner_invite WHERE status = 'pending' ORDER BY created_at DESC`)));
}
export const withdrawOwnerInvite = (s: Session, id: string) =>
  withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_owner_invite_withdraw(${id}::uuid)`));
