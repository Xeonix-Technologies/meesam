import Link from "next/link";
import { TermPicker } from "@/components/TermPicker";
import type { ReactNode } from "react";
import { notFound, redirect } from "next/navigation";
import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";
import { getDraft, listNiceClasses, listRegistries, profileRules } from "@/lib/records";
import { FILING_STEPS, filingChecks, type FilingData } from "@/lib/filing";
import { Field } from "@/components/Field";
import { COUNTRIES } from "@/components/countries";

export const dynamic = "force-dynamic";

const ATTACHMENTS = ["POA", "LGR", "APP", "OTH"] as const;

/** Filing request (Owner 3.5 / Agency 3.5; System Description Section 6), field groups following the MoET form. */
export default async function FilingStep({ params, searchParams }: { params: Promise<{ locale: string; draftId: string; step: string }>; searchParams: Promise<{ error?: string }> }) {
  const { locale, draftId, step: stepRaw } = await params;
  const { error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const step = Number(stepRaw);
  if (!(step >= 1 && step <= FILING_STEPS)) notFound();
  const draft = await getDraft(session, draftId);
  if (!draft || draft.kind !== "filing") notFound();
  if (draft.status === "committed" && draft.record_id) redirect(`/${locale}/records/${draft.record_id}`);
  const t = translator(locale);
  const d = draft.data as unknown as FilingData;
  const base = `/${locale}/records/request/${draftId}`;
  const action = `/api/filing/${draftId}/step`;
  const hidden = <><input type="hidden" name="locale" value={locale} /><input type="hidden" name="step" value={step} /></>;
  const country = (code?: string) => { const c = COUNTRIES.find((x) => x.code === code); return c ? (locale === "ar" ? c.ar : c.en) : code ?? "—"; };

  const Frame = ({ children }: { children: ReactNode }) => (
    <section className="card wizard">
      <ol className="wizard-steps" aria-label={t("filing.title")}>
        {Array.from({ length: FILING_STEPS }, (_, i) => i + 1).map((n) => (
          <li key={n} className={n === step ? "active" : n < step ? "done" : ""}><span className="n">{n}</span><span>{t(`filing.steps.${n}`)}</span></li>
        ))}
      </ol>
      <h1>{t(`filing.steps.${step}`)}</h1>
      {error ? <p className="error" role="alert">{t(`filing.errors.${error}`)}</p> : null}
      {children}
      {step > 1 ? <p className="muted small"><Link href={`${base}/${step - 1}`}>{t("common.back")}</Link></p> : null}
    </section>
  );
  const next = <div className="actions"><span /><button className="button" type="submit">{t("common.continue")}</button></div>;

  // ---- 1. applicant
  if (step === 1) {
    return (
      <Frame>
        <p className="lead">{t("filing.applicantLead")}</p>
        <form method="post" action={action} className="form">
          {hidden}
          <div className="grid-2">
            <Field label={t("filing.applicantNameAr")} name="applicant_name_ar" required={false}><input id="applicant_name_ar" name="applicant_name_ar" dir="rtl" lang="ar" defaultValue={d.applicant_name_ar ?? ""} /></Field>
            <Field label={t("filing.applicantNameEn")} name="applicant_name_en" required={false}><input id="applicant_name_en" name="applicant_name_en" dir="ltr" lang="en" defaultValue={d.applicant_name_en ?? ""} /></Field>
            <Field label={t("filing.legalForm")} name="legal_form" required={false} hint={t("filing.legalFormHint")}><input id="legal_form" name="legal_form" defaultValue={d.legal_form ?? ""} /></Field>
            <Field label={t("filing.nationality")} name="nationality" required={false}>
              <select id="nationality" name="nationality" defaultValue={d.nationality ?? "AE"}>{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{locale === "ar" ? c.ar : c.en}</option>)}</select>
            </Field>
          </div>
          <Field label={t("filing.address")} name="address" required={false}><input id="address" name="address" defaultValue={d.address ?? ""} /></Field>
          <div className="grid-2">
            <Field label={t("filing.email")} name="contact_email" required={false}><input id="contact_email" name="contact_email" type="email" dir="ltr" defaultValue={d.contact_email ?? ""} /></Field>
            <Field label={t("filing.phone")} name="contact_phone" required={false}><input id="contact_phone" name="contact_phone" dir="ltr" inputMode="tel" defaultValue={d.contact_phone ?? ""} /></Field>
          </div>
          {next}
        </form>
      </Frame>
    );
  }

  // ---- 2. registry and who files
  if (step === 2) {
    const registries = await listRegistries(true);
    const code = d.registry_code ?? registries[0]?.code ?? "AE";
    const rules = (await profileRules(code)) as { filing?: Record<string, Record<string, string> | string> } | null;
    const filing = rules?.filing ?? {};
    const text = (k: string) => { const v = filing[k]; return v && typeof v === "object" ? pickText(v, locale) : typeof v === "string" ? v : null; };
    const agencies = (await withAccount(db(), { accountId: session.accountId, userId: session.userId }, (tx) =>
      tx.execute(sql`SELECT a.agency_account_id AS id, ac.name FROM core.appointment a JOIN core.account ac ON ac.id = a.agency_account_id
                     WHERE a.owner_account_id = ${session.accountId}::uuid AND a.status = 'accepted' AND a.ended_at IS NULL`))) as unknown as Array<{ id: string; name: Record<string, string> }>;
    return (
      <Frame>
        <form method="post" action={action} className="form">
          {hidden}
          <Field label={t("intake.registry")} name="registry_code">
            <select id="registry_code" name="registry_code" required defaultValue={code}>{registries.map((r) => <option key={r.code} value={r.code}>{pickText(r.name, locale)}</option>)}</select>
          </Field>
          <div className="ms-note ms-note--info">
            <div>
              <div className="ms-note__t">{t("filing.registryRules")}</div>
              <dl className="ms-kv">
                {text("who_may_file") ? <><dt>{t("filing.rule.whoMayFile")}</dt><dd>{text("who_may_file")}</dd></> : null}
                {text("foreign_applicant") ? <><dt>{t("filing.rule.foreign")}</dt><dd>{text("foreign_applicant")}</dd></> : null}
                {text("power_of_attorney") ? <><dt>{t("filing.rule.poa")}</dt><dd>{text("power_of_attorney")}</dd></> : null}
                {text("classes_per_application") ? <><dt>{t("filing.rule.classes")}</dt><dd>{text("classes_per_application")}</dd></> : null}
              </dl>
              <div className="ms-cap">{t("filing.rulesNote")}</div>
            </div>
          </div>
          <fieldset className="field">
            <legend className="field-label">{t("filing.whoFiles")} *</legend>
            <label className="choice-row"><input type="radio" name="route" value="self" defaultChecked={d.route !== "agency"} /> <span><b>{t("filing.routeSelf")}</b><br /><span className="muted small">{t("filing.routeSelfNote")}</span></span></label>
            <label className="choice-row"><input type="radio" name="route" value="agency" defaultChecked={d.route === "agency"} /> <span><b>{t("filing.routeAgency")}</b><br /><span className="muted small">{t("filing.routeAgencyNote")}</span></span></label>
          </fieldset>
          {agencies.length ? (
            <Field label={t("filing.appointedAgency")} name="agency_account_id" required={false}>
              <select id="agency_account_id" name="agency_account_id" defaultValue={d.agency_account_id ?? ""}><option value="">—</option>{agencies.map((a) => <option key={a.id} value={a.id}>{pickText(a.name, locale)}</option>)}</select>
            </Field>
          ) : (
            <Field label={t("filing.agencyNamed")} name="agency_named" required={false} hint={t("filing.agencyNamedHint")}><input id="agency_named" name="agency_named" defaultValue={d.agency_named ?? ""} /></Field>
          )}
          {next}
        </form>
      </Frame>
    );
  }

  // ---- 3. mark
  if (step === 3) {
    const image = draft.uploads.find((u) => u.purpose === "mark_image");
    return (
      <Frame>
        <form method="post" action={action} className="form">
          {hidden}
          <fieldset className="field">
            <legend className="field-label">{t("intake.markType")} *</legend>
            <div className="grid-3">
              {(["word", "device", "combined"] as const).map((m) => (
                <label key={m} className="choice-row"><input type="radio" name="mark_type" value={m} required defaultChecked={(d.mark_type ?? "word") === m} /> <span>{t(`intake.markTypes.${m}`)}</span></label>
              ))}
            </div>
          </fieldset>
          <div className="grid-2">
            <Field label={t("intake.markTextAr")} name="mark_text_ar" required={false}><input id="mark_text_ar" name="mark_text_ar" dir="rtl" lang="ar" defaultValue={d.mark_text_ar ?? ""} /></Field>
            <Field label={t("intake.markTextEn")} name="mark_text_en" required={false}><input id="mark_text_en" name="mark_text_en" dir="ltr" lang="en" defaultValue={d.mark_text_en ?? ""} /></Field>
            <Field label={t("filing.transliteration")} name="transliteration" required={false} hint={t("filing.transliterationHint")}><input id="transliteration" name="transliteration" defaultValue={d.transliteration ?? ""} /></Field>
            <Field label={t("filing.translation")} name="translation" required={false}><input id="translation" name="translation" defaultValue={d.translation ?? ""} /></Field>
            <Field label={t("filing.colourClaim")} name="colour_claim" required={false} hint={t("filing.colourClaimHint")}><input id="colour_claim" name="colour_claim" defaultValue={d.colour_claim ?? ""} /></Field>
            <Field label={t("filing.description")} name="description" required={false}><input id="description" name="description" defaultValue={d.description ?? ""} /></Field>
          </div>
          {next}
        </form>
        <form method="post" action={`/api/intake/${draftId}/upload`} encType="multipart/form-data" className="form upload-form">
          <input type="hidden" name="locale" value={locale} /><input type="hidden" name="return_step" value="3" /><input type="hidden" name="purpose" value="mark_image" /><input type="hidden" name="doc_type" value="OTH" />
          <Field label={image ? t("filing.imageReplace", { file: image.file_name }) : t("filing.image")} name="file" required={false} hint={t("filing.imageHint")}><input id="file" name="file" type="file" accept=".png,.jpg,.jpeg,.webp" required /></Field>
          <div className="actions"><span className="muted small">{t("filing.imageNote")}</span><button type="submit" className="button-secondary">{t("intake.documents.upload")}</button></div>
        </form>
      </Frame>
    );
  }

  // ---- 4. classes and goods
  if (step === 4) {
    const classes = await listNiceClasses();
    const chosen = new Set(d.classes ?? []);
    return (
      <Frame>
        <p className="lead">{t("filing.classesLead")}</p>
        <form method="post" action={action} className="form">
          {hidden}
          <fieldset className="field">
            <legend className="field-label">{t("intake.classes")} *</legend>
            <div className="class-grid">
              {classes.map((c) => (
                <label key={c.number} className="class-chip" title={pickText(c.heading, locale)}><input type="checkbox" name="classes" value={c.number} defaultChecked={chosen.has(c.number)} /> <span>{c.number}</span></label>
              ))}
            </div>
            <div className="actions"><span className="muted small">{t("filing.classesRefreshNote")}</span><button type="submit" name="refresh" value="1" className="button-secondary">{t("filing.classesRefresh")}</button></div>
          </fieldset>
          {classes.filter((c) => chosen.has(c.number)).map((c) => (
            <div key={c.number} className="class-edit">
              <div><b className="num">{c.number}</b></div>
              <div className="form">
                <p className="small"><b>{t("record.heading")}:</b> {pickText(c.heading, locale)}</p>
                <label className="check"><input type="checkbox" name="heading" value={c.number} defaultChecked={d.headings?.includes(c.number)} /> {t("filing.useHeading")}</label>
                <label className="field"><span className="field-label">{t("filing.goodsFor", { n: c.number })}</span>
                  <textarea name={`goods_${c.number}`} rows={3} dir="auto" defaultValue={d.goods?.[String(c.number)] ?? ""} /></label>
                <TermPicker classNumber={c.number} lang={locale} target={`goods_${c.number}`} labels={{ search: t("filing.terms.search", { n: c.number }), add: t("filing.terms.add"), added: t("filing.terms.added"), none: t("filing.terms.none"), edition: t("filing.terms.edition") }} />
              </div>
            </div>
          ))}
          {next}
        </form>
      </Frame>
    );
  }

  // ---- 5. priority
  if (step === 5) {
    return (
      <Frame>
        <p className="lead">{t("filing.priorityLead")}</p>
        <form method="post" action={action} className="form">
          {hidden}
          <fieldset className="field">
            <legend className="field-label">{t("filing.priorityQuestion")}</legend>
            <label className="choice-row"><input type="radio" name="priority_claimed" value="no" defaultChecked={!d.priority_claimed} /> <span>{t("filing.priorityNo")}</span></label>
            <label className="choice-row"><input type="radio" name="priority_claimed" value="yes" defaultChecked={Boolean(d.priority_claimed)} /> <span>{t("filing.priorityYes")}</span></label>
          </fieldset>
          <div className="grid-3">
            <Field label={t("filing.priorityCountry")} name="priority_country" required={false}>
              <select id="priority_country" name="priority_country" defaultValue={d.priority_country ?? ""}><option value="">—</option>{COUNTRIES.map((c) => <option key={c.code} value={c.code}>{locale === "ar" ? c.ar : c.en}</option>)}</select>
            </Field>
            <Field label={t("filing.priorityNumber")} name="priority_number" required={false}><input id="priority_number" name="priority_number" dir="ltr" defaultValue={d.priority_number ?? ""} /></Field>
            <Field label={t("filing.priorityDate")} name="priority_date" required={false}><input id="priority_date" name="priority_date" type="date" dir="ltr" defaultValue={d.priority_date ?? ""} /></Field>
          </div>
          {next}
        </form>
      </Frame>
    );
  }

  // ---- 6. declarations and attachments
  if (step === 6) {
    const files = draft.uploads.filter((u) => u.purpose !== "mark_image");
    return (
      <Frame>
        <p className="lead">{t("filing.attachmentsLead")}</p>
        {files.length ? (
          <ul className="doc-list">
            {files.map((u) => (
              <li key={u.object_key}>
                <span className="tag">{u.doc_type}</span> <span>{u.file_name}</span>
                <form method="post" action={`/api/intake/${draftId}/upload`} className="inline">
                  <input type="hidden" name="locale" value={locale} /><input type="hidden" name="return_step" value="6" /><input type="hidden" name="remove" value={u.object_key} />
                  <button type="submit" className="link-button">{t("intake.documents.remove")}</button>
                </form>
              </li>
            ))}
          </ul>
        ) : <p className="muted">{t("intake.documents.none")}</p>}
        <form method="post" action={`/api/intake/${draftId}/upload`} encType="multipart/form-data" className="form upload-form">
          <input type="hidden" name="locale" value={locale} /><input type="hidden" name="return_step" value="6" />
          <div className="grid-2">
            <Field label={t("intake.documents.type")} name="doc_type">
              <select id="doc_type" name="doc_type" defaultValue="POA">{ATTACHMENTS.map((c) => <option key={c} value={c}>{c} — {t(`filing.attachments.${c}`)}</option>)}</select>
            </Field>
            <Field label={t("intake.documents.file")} name="file" hint={t("intake.documents.fileHint")}><input id="file" name="file" type="file" accept=".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff" required /></Field>
          </div>
          <div className="actions"><span /><button type="submit" className="button-secondary">{t("intake.documents.upload")}</button></div>
        </form>
        <form method="post" action={action} className="form">
          {hidden}
          <label className="check"><input type="checkbox" name="declaration_accuracy" value="yes" defaultChecked={Boolean(d.declaration_accuracy)} /> {t("filing.declarationAccuracy")}</label>
          {next}
        </form>
      </Frame>
    );
  }

  // ---- 7. review and accept
  const issues = filingChecks(d);
  const classes = await listNiceClasses();
  const heading = (n: number) => pickText(classes.find((c) => c.number === n)?.heading ?? {}, locale);
  const row = (label: string, value: string | undefined | null, to: number) => (
    <tr key={label}><th>{label}</th><td>{value || "—"}</td><td className="small"><Link href={`${base}/${to}`}>{t("intake.review.change")}</Link></td></tr>
  );
  return (
    <Frame>
      <p className="lead">{t("filing.reviewLead")}</p>
      <table className="review"><tbody>
        {row(t("filing.steps.1"), [d.applicant_name_ar, d.applicant_name_en].filter(Boolean).join(" · "), 1)}
        {row(t("filing.nationality"), country(d.nationality), 1)}
        {row(t("filing.address"), d.address, 1)}
        {row(t("intake.registry"), d.registry_code, 2)}
        {row(t("filing.whoFiles"), d.route === "agency" ? `${t("filing.routeAgency")}${d.agency_named ? ` — ${d.agency_named}` : ""}` : t("filing.routeSelf"), 2)}
        {row(t("intake.markType"), d.mark_type ? t(`intake.markTypes.${d.mark_type}`) : undefined, 3)}
        {row(t("record.mark"), [d.mark_text_ar, d.mark_text_en].filter(Boolean).join(" · "), 3)}
        {row(t("filing.image"), draft.uploads.find((u) => u.purpose === "mark_image")?.file_name, 3)}
        {(d.classes ?? []).map((n) => row(`${t("record.classNumber")} ${n}`, d.headings?.includes(n) ? `${t("filing.headingUsed")}: ${heading(n)}` : d.goods?.[String(n)], 4))}
        {row(t("filing.steps.5"), d.priority_claimed ? `${country(d.priority_country)} · ${d.priority_number ?? "—"} · ${d.priority_date ? formatDate(d.priority_date, locale) : "—"}` : t("filing.priorityNo"), 5)}
        {row(t("filing.steps.6"), draft.uploads.filter((u) => u.purpose !== "mark_image").map((u) => u.doc_type).join(", ") || t("dashboard.none"), 6)}
      </tbody></table>
      <form method="post" action={`/api/filing/${draftId}/commit`} className="form">
        <input type="hidden" name="locale" value={locale} />
        {issues.length ? (
          <section className="warnings">
            <h2>{t("intake.review.warningsTitle", { n: issues.length })}</h2>
            <p className="muted small">{t("filing.checksLead")}</p>
            {issues.map((w) => {
              const cls = w.field.startsWith("goods_") ? w.field.slice(6) : "";
              const to = w.field.startsWith("applicant") || w.field === "address" ? 1 : w.field.startsWith("mark") ? 3 : w.field.startsWith("priority") ? 5 : 4;
              return (
                <div key={`${w.code}:${w.field}`} className="warning">
                  <strong>{cls ? `${t("record.classNumber")} ${cls}` : t(`filing.fields.${w.field}`)}</strong>
                  <p>{t(`filing.checks.${w.code}`)} · <Link href={`${base}/${to}`}>{t("record.fixValue")}</Link></p>
                  <label className="field"><span className="field-label">{t("intake.review.confirmNote")}</span><input name={`confirm:${w.field}`} placeholder={t("intake.review.confirmPlaceholder")} /></label>
                </div>
              );
            })}
          </section>
        ) : <p className="notice">{t("intake.review.noWarnings")}</p>}
        <div className="ms-note ms-note--info"><div><div className="ms-note__t">{t("filing.notDoneTitle")}</div><div>{t("filing.notDone")}</div></div></div>
        <label className="check"><input type="checkbox" name="accept" value="yes" required /> {t("filing.accept")}</label>
        <div className="actions"><span /><button className="button" type="submit">{t("filing.create")}</button></div>
      </form>
    </Frame>
  );
}
