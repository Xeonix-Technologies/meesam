import type { translator } from "@meesam/i18n";

/** Human label for a timer type, including profile-generated reminders (`<clock>_reminder_<n>m`). */
export function timerLabel(t: ReturnType<typeof translator>, type: string | null | undefined): string {
  if (!type) return "";
  const m = type.match(/^(.*)_reminder_(\d+)m$/);
  if (!m) return t(`timers.${type}`);
  const n = Number(m[2]);
  const months = n === 1 ? t("timers.oneMonth") : t("timers.nMonths", { n });
  // renewal reminders run up to expiry (registry profile: reminders.before = expiry)
  return m[1] === "renewal_window" ? t("timers.renewalReminder", { months }) : t("timers.reminder", { clock: t(`timers.${m[1]}`), months });
}

/** Whole days from today to an ISO date (negative when past). */
export const daysUntil = (d: string) => Math.round((new Date(`${d.slice(0, 10)}T00:00:00Z`).getTime() - Date.now()) / 86400000);
