import { sql } from "drizzle-orm";
import { withAccount, withRole } from "@meesam/db";
import { translator, pickText, type Locale } from "@meesam/i18n";
import { db } from "./db";
import { newToken, sha256, type Session } from "./session";
import { timerLabel } from "./timers";

/**
 * Calendar feed (System Description 4.11 "Calendar"; migration 0036). Dates are all-day events on the
 * registry's own local date, so one deadline reads the same in Dubai, Washington or London; the note
 * on each event names the registry's time zone and the 23:59 cut-off.
 */
const ctx = (s: Session) => ({ accountId: s.accountId, userId: s.userId });
const rows = <T = Record<string, unknown>>(r: unknown) => r as unknown as T[];

export interface CalEvent { timer_id: string; record_id: string; timer_type: string; due_date: string | Date; timezone: string; mark_text: Record<string, string> | null; number: string | null; registry_code: string; updated_at?: string | Date | null }

/** Switches the feed on (or replaces its link) and returns the secret for the link; only its hash is stored. */
export async function resetFeed(s: Session): Promise<string> {
  const { token, hash } = newToken();
  await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_calendar_feed_set(${hash})`));
  return token;
}
export const feedOff = (s: Session) => withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT core.fn_calendar_feed_off()`));
export async function feedStatus(s: Session): Promise<{ created_at: string | null; last_read_at: string | null }> {
  const r = rows<{ created_at: string | null; last_read_at: string | null }>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`SELECT created_at, last_read_at FROM core.fn_calendar_feed_status()`)))[0];
  return { created_at: r?.created_at ?? null, last_read_at: r?.last_read_at ?? null };
}
/** The feed by its secret; null when the secret is unknown or the user is no longer entitled. */
export async function feedEvents(token: string): Promise<{ locale: Locale; accountId: string; events: CalEvent[] } | null> {
  const list = rows<CalEvent & { locale: string; account_id: string; timer_id: string | null }>(
    await withRole(db(), "meesam_app", (tx) => tx.execute(sql`SELECT * FROM core.fn_calendar_events(${sha256(token)})`)));
  if (list.length === 0) return null;
  return { locale: list[0]!.locale === "ar" ? "ar" : "en", accountId: list[0]!.account_id, events: list.filter((e) => e.timer_id) };
}
/** One open deadline of a trademark this account can see (row-level security decides). */
export async function timerEvent(s: Session, timerId: string): Promise<CalEvent | null> {
  return rows<CalEvent>(await withAccount(db(), ctx(s), (tx) => tx.execute(sql`
    SELECT t.id AS timer_id, t.record_id, t.timer_type, t.due_date, COALESCE(p.rules -> 'calendar' ->> 'timezone', 'UTC') AS timezone,
           r.mark_text, COALESCE(r.registration_no, r.application_no) AS number, g.code AS registry_code, t.updated_at
      FROM core.timer t JOIN core.record r ON r.id = t.record_id JOIN registry.registry g ON g.id = r.registry_id
      LEFT JOIN registry.registry_profile p ON p.registry_id = r.registry_id
     WHERE t.id = ${timerId}::uuid AND t.due_date IS NOT NULL`)))[0] ?? null;
}

const ymd = (d: string | Date) => (typeof d === "string" ? d.slice(0, 10) : d.toISOString().slice(0, 10)).replace(/-/g, "");
const stamp = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const esc = (v: string) => v.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
/** RFC 5545 line folding: no line longer than 75 octets. */
function fold(line: string): string {
  const out: string[] = [];
  let cur = "";
  let bytes = 0;
  for (const ch of line) {
    const b = Buffer.byteLength(ch, "utf8");
    if (bytes + b > (out.length ? 74 : 75)) { out.push(cur); cur = ch; bytes = b; } else { cur += ch; bytes += b; }
  }
  out.push(cur);
  return out.join("\r\n ");
}

/** An iCalendar file of the given deadlines, in the reader's language. */
export function toIcs(events: CalEvent[], locale: Locale, base: string, accountId?: string): string {
  const t = translator(locale);
  const now = stamp(new Date());
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Meesam//Deadlines//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    `X-WR-CALNAME:${esc(t("calendar.name"))}`, "REFRESH-INTERVAL;VALUE=DURATION:PT6H", "X-PUBLISHED-TTL:PT6H"];
  for (const e of events) {
    const start = ymd(e.due_date);
    const next = new Date(Date.UTC(Number(start.slice(0, 4)), Number(start.slice(4, 6)) - 1, Number(start.slice(6, 8)) + 1));
    const mark = `${pickText(e.mark_text, locale) || e.number || "—"} (${e.registry_code}${e.number ? ` ${e.number}` : ""})`;
    const link = `${base}/${locale}/records/${e.record_id}${accountId ? `?for=${accountId}` : ""}`;
    lines.push("BEGIN:VEVENT", `UID:${e.timer_id}@meesam`, `DTSTAMP:${now}`,
      `DTSTART;VALUE=DATE:${start}`, `DTEND;VALUE=DATE:${ymd(next)}`,
      `SUMMARY:${esc(`${timerLabel(t, e.timer_type)} — ${mark}`)}`,
      `DESCRIPTION:${esc(`${t("calendar.note", { timezone: e.timezone })}\n${t("calendar.check")}\n${link}`)}`,
      `URL:${link}`, "TRANSP:TRANSPARENT", "END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return lines.map(fold).join("\r\n") + "\r\n";
}
