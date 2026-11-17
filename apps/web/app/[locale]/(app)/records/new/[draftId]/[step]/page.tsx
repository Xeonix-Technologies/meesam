import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { sql } from "drizzle-orm";
import { withAccount } from "@meesam/db";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { db } from "@/lib/db";
import { getSession } from "@/lib/session";
import { getDraft, listNiceClasses, listRegistries, profileRules, saveDraftWarnings } from "@/lib/records";
import { INTAKE_STAGES, reachedAtLeast, runChecks } from "@/lib/checks";
import { DOC_TYPES } from "@/lib/upload";
import { Field } from "@/components/Field";
import { WizardFrame } from "@/components/intake";

export const dynamic = "force-dynamic";

export default async function IntakeStep({ params, searchParams }: { params: Promise<{ locale: string; draftId: string; step: string }>; searchParams: Promise<{ error?: string; notice?: string; n?: string }> }) {
  const { locale, draftId, step: stepRaw } = await params;
  const { error, notice, n: noticeN } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const step = Number(stepRaw);
  if (!(step >= 1 && step <= 6)) notFound();
  const draft = await getDraft(session, draftId);
  if (!draft) notFound();
  if (draft.status === "committed" && draft.record_id) redirect(`/${locale}/records/${draft.record_id}`);
  const t = translator(locale);
  const d = draft.data;
  const hidden = (
    <>
      <input type="hidden" name="locale" value={locale} />
      <input type="hidden" name="step" value={step} />
    </>
  );
  const action = `/api/intake/${draftId}/step`;
  const sources = d._sources ?? {};
  /** "Read from <file>: '<passage>'" under a field the reader filled; nothing when the user typed it. */
  const readFrom = (field: string) => {
    const src = sources[field];
    if (!src) return undefined;
    return `${t("intake.readFrom", { file: src.file })}${src.quote ? ` — “${src.quote}”` : ""}`;
  };
  const readTag = (field: string) => (sources[field] ? <span className="ms-tag ai-tag">{t("intake.readByAi")}</span> : null);
  const title = t(`intake.steps.${step}`);

  // ---- 1. who manages this mark
  if (step === 1) {
    const agencies = (await withAccount(db(), { accountId: session.accountId, userId: session.userId }, (tx) =>
      tx.execute(sql`SELECT a.agency_account_id AS id, ac.name FROM core.appointment a JOIN core.account ac ON ac.id = a.agency_account_id
                     WHERE a.owner_account_id = ${session.accountId}::uuid AND a.status = 'accepted' AND a.ended_at IS NULL`))) as unknown as Array<{ id: string; name: Record<string, string> }>;
    const isAgency = session.accountKind === "agency_office";
    return (
      <WizardFrame t={t} locale={locale} draftId={draftId} step={1} title={title} error={error}>
        <p className="lead">{t("intake.manager.lead")}</p>
        <form method="post" action={action} className="form">
          {hidden}
          <label className="choice-row"><input type="radio" name="manager" value="self" defaultChecked={d.manager !== "agency"} /> <span>{isAgency ? t("intake.manager.agencySelf") : t("intake.manager.self")}</span></label>
          {!isAgency && agencies.map((a) => (
            <label key={a.id} className="choice-row">
              <input type="radio" name="manager" value="agency" defaultChecked={d.manager === "agency" && d.agency_account_id === a.id} />
              <input type="hidden" name="agency_account_id" value={a.id} />
              <span>{t("intake.manager.agency", { name: pickText(a.name, locale) })}</span>
            </label>
          ))}
          {!isAgency && agencies.length === 0 ? <p className="muted small">{t("intake.manager.noAgency")}</p> : null}
          <div className="actions"><span /><button className="button" type="submit">{t("common.continue")}</button></div>
        </form>
      </WizardFrame>
    );
  }

  // ---- 2. registry and stage
  if (step === 2) {
    const registries = await listRegistries(true);
    return (
      <WizardFrame t={t} locale={locale} draftId={draftId} step={2} title={title} error={error}>
        <form method="post" action={action} className="form">
          {hidden}
          <Field label={t("intake.registry")} name="registry_code" hint={readFrom("registry_code")}>
            <select id="registry_code" name="registry_code" required defaultValue={d.registry_code ?? registries[0]?.code}>
              {registries.map((r) => <option key={r.code} value={r.code}>{pickText(r.name, locale)}</option>)}
            </select>
          </Field>
          <p className="muted small">{t("intake.registryNote")}</p>
          <fieldset className="field">
            <legend className="field-label">{t("intake.stageReached")} * {readTag("stage")}</legend>
            {readFrom("stage") ? <p className="field-hint">{readFrom("stage")}</p> : null}
            {INTAKE_STAGES.map((s) => (
              <label key={s} className="choice-row"><input type="radio" name="stage" value={s} required defaultChecked={d.stage === s} /> <span>{t(`intake.stage.${s}`)}</span></label>
            ))}
          </fieldset>
          <div className="actions"><span /><button className="button" type="submit">{t("common.continue")}</button></div>
        </form>
      </WizardFrame>
    );
  }

  // ---- 3. mark and classes
  if (step === 3) {
    const classes = await listNiceClasses();
    const chosen = new Set(d.classes ?? []);
    return (
      <WizardFrame t={t} locale={locale} draftId={draftId} step={3} title={title} error={error}>
        <form method="post" action={action} className="form">
          {hidden}
          <fieldset className="field">
            <legend className="field-label">{t("intake.markType")} * {readTag("mark_type")}</legend>
            {readFrom("mark_type") ? <p className="field-hint">{readFrom("mark_type")}</p> : null}
            {(["word", "device", "combined"] as const).map((m) => (
              <label key={m} className="choice-row"><input type="radio" name="mark_type" value={m} required defaultChecked={(d.mark_type ?? "word") === m} /> <span>{t(`intake.markTypes.${m}`)}</span></label>
            ))}
          </fieldset>
          <div className="grid-2">
            <Field label={t("intake.markTextAr")} name="mark_text_ar" required={false} hint={readFrom("mark_text_ar")}><input id="mark_text_ar" name="mark_text_ar" dir="rtl" lang="ar" defaultValue={d.mark_text_ar ?? ""} /></Field>
            <Field label={t("intake.markTextEn")} name="mark_text_en" required={false} hint={readFrom("mark_text_en")}><input id="mark_text_en" name="mark_text_en" dir="ltr" lang="en" defaultValue={d.mark_text_en ?? ""} /></Field>
          </div>
          <p className="muted small">{t("intake.imageLater")}</p>
          <fieldset className="field">
            <legend className="field-label">{t("intake.classes")} * {readTag("classes")}</legend>
            <div className="class-grid">
              {classes.map((c) => (
                <label key={c.number} className="class-chip" title={pickText(c.heading, locale)}>
                  <input type="checkbox" name="classes" value={c.number} defaultChecked={chosen.has(c.number)} /> <span>{c.number}</span>
                </label>
              ))}
            </div>
            <span className="field-hint">{t("intake.classesHint")}</span>
          </fieldset>
          <Field label={t("intake.goods")} name="goods" required={false} hint={t("intake.goodsHint")}>
            <textarea id="goods" name="goods" rows={4} defaultValue={d.goods ?? ""} />
          </Field>
          <div className="actions"><span /><button className="button" type="submit">{t("common.continue")}</button></div>
        </form>
      </WizardFrame>
    );
  }

  // ---- 4. numbers and dates for the stage reached
  if (step === 4) {
    const st = d.stage;
    const dateInput = (name: keyof typeof d) => <input id={name} name={name} type="date" defaultValue={(d[name] as string | undefined) ?? ""} dir="ltr" />;
    return (
      <WizardFrame t={t} locale={locale} draftId={draftId} step={4} title={title} error={error} notice={notice}>
        <form method="post" action={action} className="form">
          {hidden}
          <div className="grid-2">
            <Field label={t("intake.applicationNo")} name="application_no" required={false} hint={readFrom("application_no")}><input id="application_no" name="application_no" dir="ltr" defaultValue={d.application_no ?? ""} /></Field>
            <Field label={t("intake.filingDate")} name="filing_date" required={false} hint={readFrom("filing_date")}>{dateInput("filing_date")}</Field>
          </div>
          {reachedAtLeast(st, "accepted") ? <Field label={t("intake.acceptanceDate")} name="acceptance_date" required={false} hint={readFrom("acceptance_date")}>{dateInput("acceptance_date")}</Field> : null}
          {reachedAtLeast(st, "published") ? (
            <div className="grid-2">
              <Field label={t("intake.publicationDate")} name="publication_date" required={false} hint={readFrom("publication_date")}>{dateInput("publication_date")}</Field>
              <Field label={t("intake.oppositionEnd")} name="opposition_end" required={false} hint={readFrom("opposition_end") ?? t("intake.oppositionEndHint")}>{dateInput("opposition_end")}</Field>
            </div>
          ) : null}
          {reachedAtLeast(st, "registered") ? (
            <>
              <div className="grid-2">
                <Field label={t("intake.registrationNo")} name="registration_no" required={false} hint={readFrom("registration_no")}><input id="registration_no" name="registration_no" dir="ltr" defaultValue={d.registration_no ?? ""} /></Field>
                <Field label={t("intake.registrationDate")} name="registration_date" required={false} hint={readFrom("registration_date")}>{dateInput("registration_date")}</Field>
              </div>
              <Field label={t("intake.expiryDate")} name="expiry_date" required={false} hint={readFrom("expiry_date") ?? t("intake.expiryHint")}>{dateInput("expiry_date")}</Field>
            </>
          ) : null}
          {reachedAtLeast(st, "renewed") ? <Field label={t("intake.renewalDate")} name="renewal_date" required={false} hint={readFrom("renewal_date")}>{dateInput("renewal_date")}</Field> : null}
          <div className="actions"><span /><button className="button" type="submit">{t("common.continue")}</button></div>
        </form>
      </WizardFrame>
    );
  }

  // ---- 5. documents
  if (step === 5) {
    const minimum = ["ORC", "POA"];
    return (
      <WizardFrame t={t} locale={locale} draftId={draftId} step={5} title={title} error={error}>
        <p className="lead">{t("intake.documents.leadFirst")}</p>
        {notice === "read" ? <p className="notice" role="status">{t("intake.notices.read", { n: noticeN ?? "0" })}</p> : null}
        {notice === "readNothing" ? <p className="notice" role="status">{t("intake.notices.readNothing")}</p> : null}
        {notice === "readFailed" ? <p className="error" role="alert">{t("intake.notices.readFailed")}</p> : null}
        {notice === "noReader" ? <p className="muted small">{t("intake.notices.noReader")}</p> : null}
        {draft.uploads.length ? (
          <ul className="doc-list">
            {draft.uploads.map((u) => (
              <li key={u.object_key}>
                <span className="tag">{u.doc_type}</span> <span>{u.file_name}</span>
                {u.extraction_status === "extracted" ? <span className="ms-tag ai-tag">{t("intake.readByAi")}</span> : u.extraction_status === "failed" ? <span className="flag flag-amber">{t("intake.readFailedTag")}</span> : null}
                <form method="post" action={`/api/intake/${draftId}/upload`} className="inline">
                  <input type="hidden" name="locale" value={locale} /><input type="hidden" name="remove" value={u.object_key} />
                  <button type="submit" className="link-button">{t("intake.documents.remove")}</button>
                </form>
              </li>
            ))}
          </ul>
        ) : <p className="muted">{t("intake.documents.none")}</p>}
        <form method="post" action={`/api/intake/${draftId}/upload`} encType="multipart/form-data" className="form upload-form">
          <input type="hidden" name="locale" value={locale} />
          <div className="grid-2">
            <Field label={t("intake.documents.type")} name="doc_type">
              <select id="doc_type" name="doc_type" defaultValue="ORC">{DOC_TYPES.map((c) => <option key={c} value={c}>{c} — {t(`docTypes.${c}`)}</option>)}</select>
            </Field>
            <Field label={t("intake.documents.file")} name="file" hint={t("intake.documents.fileHint")}><input id="file" name="file" type="file" accept=".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff" required /></Field>
          </div>
          <div className="actions"><span className="muted small">{t("intake.documents.minimum", { types: minimum.join(", ") })}</span><button type="submit" className="button-secondary">{t("intake.documents.uploadRead")}</button></div>
        </form>
        <form method="post" action={action} className="form">
          {hidden}
          <div className="actions"><span className="muted small">{draft.uploads.length ? t("intake.documents.continueRead") : t("intake.documents.continueManual")}</span><button className="button" type="submit">{t("intake.documents.continue")}</button></div>
        </form>
      </WizardFrame>
    );
  }

  // ---- 6. review, accept and consistency checks
  const rules = d.registry_code ? await profileRules(d.registry_code) : null;
  const warnings = runChecks(d, rules);
  await saveDraftWarnings(session, draftId, warnings);
  const fmt = (v?: string) => (v ? formatDate(v, locale) : "—");
  const rowsToShow: Array<[string, string | undefined, number, string | null]> = [
    [t("intake.registry"), d.registry_code, 2, "registry_code"], [t("intake.stageReached"), d.stage ? t(`intake.stage.${d.stage}`) : undefined, 2, "stage"],
    [t("intake.markType"), d.mark_type ? t(`intake.markTypes.${d.mark_type}`) : undefined, 3, "mark_type"], [t("intake.markTextAr"), d.mark_text_ar, 3, "mark_text_ar"], [t("intake.markTextEn"), d.mark_text_en, 3, "mark_text_en"],
    [t("intake.classes"), (d.classes ?? []).join(", "), 3, "classes"], [t("intake.applicationNo"), d.application_no, 4, "application_no"], [t("intake.filingDate"), fmt(d.filing_date), 4, "filing_date"],
    [t("intake.acceptanceDate"), d.acceptance_date ? fmt(d.acceptance_date) : undefined, 4, "acceptance_date"], [t("intake.publicationDate"), d.publication_date ? fmt(d.publication_date) : undefined, 4, "publication_date"],
    [t("intake.registrationNo"), d.registration_no, 4, "registration_no"], [t("intake.registrationDate"), d.registration_date ? fmt(d.registration_date) : undefined, 4, "registration_date"], [t("intake.expiryDate"), d.expiry_date ? fmt(d.expiry_date) : undefined, 4, "expiry_date"],
    [t("intake.documents.title"), draft.uploads.map((u) => u.doc_type).join(", ") || t("dashboard.none"), 5, null],
  ];
  const readCount = Object.keys(sources).length;
  return (
    <WizardFrame t={t} locale={locale} draftId={draftId} step={6} title={title} error={error}>
      <p className="lead">{t("intake.review.lead")}</p>
      {readCount ? <p className="muted small">{t("intake.review.readLead", { n: readCount })}</p> : null}
      <table className="review">
        <thead><tr><th>{t("intake.review.field")}</th><th>{t("intake.review.value")}</th><th>{t("intake.review.readFromCol")}</th><th /></tr></thead>
        <tbody>
          {rowsToShow.filter(([, v]) => v !== undefined).map(([k, v, s, f]) => {
            const src = f ? sources[f] : undefined;
            return (
              <tr key={k}><th>{k}</th><td>{v || "—"} {f ? readTag(f) : null}</td>
                <td className="small muted">{src ? <>{src.file}{src.quote ? <> — “{src.quote}”</> : null}</> : f ? t("intake.review.typed") : ""}</td>
                <td className="small"><Link href={`/${locale}/records/new/${draftId}/${s}`}>{t("intake.review.change")}</Link></td></tr>
            );
          })}
        </tbody>
      </table>
      <form method="post" action={`/api/intake/${draftId}/commit`} className="form">
        <input type="hidden" name="locale" value={locale} />
        {warnings.length ? (
          <section className="warnings">
            <h2>{t("intake.review.warningsTitle", { n: warnings.length })}</h2>
            <p className="muted small">{t("intake.review.warningsLead")}</p>
            {warnings.map((w) => {
              const isDate = w.field.endsWith("_date") || w.field === "opposition_end";
              const current = (d as Record<string, unknown>)[w.field];
              return (
                <div key={`${w.code}:${w.field}`} className="warning">
                  <strong>{t(`intake.fields.${w.field}`)}</strong>
                  <p>{t(`checks.${w.code}`, w.params ?? {})}</p>
                  <div className="grid-2">
                    {w.field !== "classes" ? (
                      <label className="field"><span className="field-label">{t("intake.review.fixValue")}</span>
                        <input name={`fix:${w.field}`} type={isDate ? "date" : "text"} dir="ltr" defaultValue={typeof current === "string" ? current : ""} />
                      </label>
                    ) : <span className="muted small"><Link href={`/${locale}/records/new/${draftId}/3`}>{t("intake.review.change")}</Link></span>}
                    <label className="field"><span className="field-label">{t("intake.review.confirmNote")}</span><input name={`confirm:${w.code}:${w.field}`} placeholder={t("intake.review.confirmPlaceholder")} /></label>
                  </div>
                </div>
              );
            })}
          </section>
        ) : <p className="notice">{t("intake.review.noWarnings")}</p>}
        <label className="choice-row"><input type="checkbox" name="accept" value="yes" required /> <span>{t("intake.review.accept")}</span></label>
        <div className="actions"><span className="muted small">{t("intake.review.afterwards")}</span><button className="button" type="submit">{t("intake.review.create")}</button></div>
      </form>
    </WizardFrame>
  );
}
