import type { ReactNode } from "react";

export function Field({ label, name, children, hint, required = true }: { label: string; name: string; children?: ReactNode; hint?: string; required?: boolean }) {
  return (
    <label className="field" htmlFor={name}>
      <span className="field-label">{label}{required ? <span aria-hidden="true"> *</span> : null}</span>
      {children ?? <input id={name} name={name} required={required} />}
      {hint ? <span className="field-hint">{hint}</span> : null}
    </label>
  );
}
