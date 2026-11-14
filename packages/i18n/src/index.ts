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

/** Dot-path lookup, e.g. t("status.title"). Falls back to English, then to the key. */
export function translator(locale: Locale) {
  const primary = catalog[locale] as unknown as Record<string, unknown>;
  const fallback = catalog[defaultLocale] as unknown as Record<string, unknown>;
  const lookup = (obj: Record<string, unknown>, path: string): string | undefined =>
    path.split(".").reduce<unknown>((acc, k) => (acc && typeof acc === "object" ? (acc as Record<string, unknown>)[k] : undefined), obj) as string | undefined;
  return (key: string): string => lookup(primary, key) ?? lookup(fallback, key) ?? key;
}
