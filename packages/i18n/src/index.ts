import en from "../messages/en.json";
import ar from "../messages/ar.json";

/**
 * Languages are data (Data Architecture 14.2): adding a language means adding a
 * messages file and a row here, never touching components.
 */
export const locales = ["en", "ar"] as const;
export type Locale = (typeof locales)[number];
export const defaultLocale: Locale = "en";

export const localeMeta: Record<Locale, { dir: "ltr" | "rtl"; label: string; htmlLang: string }> = {
  en: { dir: "ltr", label: "English", htmlLang: "en" },
  ar: { dir: "rtl", label: "العربية", htmlLang: "ar" },
};

export type Messages = typeof en;
const catalog: Record<Locale, Messages> = { en, ar: ar as Messages };

export function isLocale(value: string | undefined): value is Locale {
  return !!value && (locales as readonly string[]).includes(value);
}

export function getMessages(locale: Locale): Messages {
  return catalog[locale];
}

export type Translator = (key: string, vars?: Record<string, string | number>) => string;

/** Dot-path lookup, e.g. t("status.title") or t("mail.verify.body", { name }). Falls back to English, then to the key. */
export function translator(locale: Locale): Translator {
  const primary = catalog[locale] as unknown as Record<string, unknown>;
  const fallback = catalog[defaultLocale] as unknown as Record<string, unknown>;
  const lookup = (obj: Record<string, unknown>, path: string): string | undefined =>
    path.split(".").reduce<unknown>((acc, k) => (acc && typeof acc === "object" ? (acc as Record<string, unknown>)[k] : undefined), obj) as string | undefined;
  return (key, vars) => {
    const raw = lookup(primary, key) ?? lookup(fallback, key) ?? key;
    return vars ? raw.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m)) : raw;
  };
}

/** Picks the bilingual text in the locale, falling back to any language present (item 22). */
export function pickText(value: Record<string, string | undefined> | null | undefined, locale: Locale): string {
  if (!value) return "";
  return value[locale] ?? value[defaultLocale] ?? Object.values(value).find((v) => !!v) ?? "";
}

/** Formats an amount of money in the locale, with the currency's code and Western digits in Arabic too. */
export function formatMoney(value: number | string, locale: Locale, currency = "AED"): string {
  return new Intl.NumberFormat(locale === "ar" ? "ar-AE-u-nu-latn" : "en-GB", { style: "currency", currency, currencyDisplay: "code", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value));
}

/** Formats a date in the locale with Western digits in Arabic too (dates must stay machine-readable). */
export function formatDate(value: Date | string, locale: Locale): string {
  const d = typeof value === "string" ? new Date(value) : value;
  return new Intl.DateTimeFormat(locale === "ar" ? "ar-AE-u-nu-latn" : "en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(d);
}

/** Date and time of an entry (messages), shown in Gulf Standard Time for the pilot; the time zone is named so it is never ambiguous. */
export function formatDateTime(value: Date | string, locale: Locale, timeZone = "Asia/Dubai"): string {
  const d = typeof value === "string" ? new Date(value) : value;
  return new Intl.DateTimeFormat(locale === "ar" ? "ar-AE-u-nu-latn" : "en-GB", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: false, timeZone, timeZoneName: "short" }).format(d);
}

/** Time of an entry with the time zone named (Gulf Standard Time on the server; the browser shows the reader's own zone). */
export function formatTime(value: Date | string, locale: Locale, timeZone = "Asia/Dubai"): string {
  const d = typeof value === "string" ? new Date(value) : value;
  return new Intl.DateTimeFormat(locale === "ar" ? "ar-AE-u-nu-latn" : "en-GB", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone, timeZoneName: "short" }).format(d);
}
