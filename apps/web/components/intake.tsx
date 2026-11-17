import Link from "next/link";
import type { ReactNode } from "react";
import type { Translator, Locale } from "@meesam/i18n";

/**
 * Display order of the intake steps (internal ids stay stable in URLs and routes). The documents step comes
 * right after "who manages it": the certificate is uploaded first and the reader fills what follows
 * (Founder, 16 Nov 2026; System Description 4.7 step 5).
 */
export const STEP_ORDER = [1, 5, 2, 3, 4, 6] as const;
export const position = (step: number) => STEP_ORDER.indexOf(step as (typeof STEP_ORDER)[number]) + 1;
export const nextStep = (step: number) => STEP_ORDER[Math.min(position(step), STEP_ORDER.length - 1)] ?? 6;
export const prevStep = (step: number) => (position(step) > 1 ? STEP_ORDER[position(step) - 2] ?? 1 : null);

export function Steps({ t, current }: { t: Translator; current: number }) {
  const cur = position(current);
  return (
    <ol className="wizard-steps" aria-label={t("intake.title")}>
      {STEP_ORDER.map((id, i) => (
        <li key={id} className={i + 1 === cur ? "active" : i + 1 < cur ? "done" : ""}>
          <span className="n">{i + 1}</span>
          <span>{t(`intake.steps.${id}`)}</span>
        </li>
      ))}
    </ol>
  );
}

export function WizardFrame({ t, locale, draftId, step, title, children, error, notice }: { t: Translator; locale: Locale; draftId: string; step: number; title: string; children: ReactNode; error?: string | null; notice?: string | null }) {
  return (
    <section className="card wizard">
      <Steps t={t} current={step} />
      <h1>{title}</h1>
      {error ? <p className="error" role="alert">{t(`intake.errors.${error}`)}</p> : null}
      {notice ? <p className="notice" role="status">{t(`intake.notices.${notice}`)}</p> : null}
      {children}
      {prevStep(step) ? <p className="muted small"><Link href={`/${locale}/records/new/${draftId}/${prevStep(step)}`}>{t("common.back")}</Link></p> : null}
    </section>
  );
}
