import type { ReactNode } from "react";

/** One labelled control. With `error`, the field is highlighted and the message shown under it. */
export function Field({ label, name, children, hint, error, required = true, defaultValue }: {
  label: string; name: string; children?: ReactNode; hint?: string; error?: string; required?: boolean; defaultValue?: string;
}) {
  return (
    <label className={error ? "field field-invalid" : "field"} htmlFor={name}>
      <span className="field-label">{label}{required ? <span aria-hidden="true"> *</span> : null}</span>
      {children ?? <input id={name} name={name} required={required} defaultValue={defaultValue} aria-invalid={error ? true : undefined} />}
      {error ? <span className="field-error" role="alert">{error}</span> : hint ? <span className="field-hint">{hint}</span> : null}
    </label>
  );
}
