import Link from "next/link";
import type { ReactNode } from "react";
import type { Translator, Locale } from "@meesam/i18n";

export function Steps({ t, current, total = 6 }: { t: Translator; current: number; total?: number }) {
  return (
    <ol className="wizard-steps" aria-label={t("intake.title")}>
      {Array.from({ length: total }, (_, i) => i + 1).map((n) => (
        <li key={n} className={n === current ? "active" : n < current ? "done" : ""}>
          <span className="n">{n}</span>
          <span>{t(`intake.steps.${n}`)}</span>
        </li>
      ))}
    </ol>
  );
}

export function WizardFrame({ t, locale, draftId, step, title, children, error }: { t: Translator; locale: Locale; draftId: string; step: number; title: string; children: ReactNode; error?: string | null }) {
  return (
    <section className="card wizard">
      <Steps t={t} current={step} />
      <h1>{title}</h1>
      {error ? <p className="error" role="alert">{t(`intake.errors.${error}`)}</p> : null}
      {children}
      {step > 1 ? <p className="muted small"><Link href={`/${locale}/records/new/${draftId}/${step - 1}`}>{t("common.back")}</Link></p> : null}
    </section>
  );
}
