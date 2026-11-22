import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { PageHead, Panel } from "@/components/ms";

export const dynamic = "force-dynamic";

/** Feedback from a signed-in user (Founder ruling R11, 21 Nov 2026). Read by Meesam staff; not a support channel. */
export default async function Feedback({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string; from?: string }> }) {
  const { locale } = await params;
  const { saved, error, from } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const t = translator(locale);
  return (
    <>
      <PageHead title={t("feedback.title")} sub={t("feedback.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t("feedback.saved")}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`feedback.errors.${error}`)}</div></div> : null}
      <Panel title={t("feedback.form")}>
        <form method="post" action="/api/feedback" className="ms-stack">
          <input type="hidden" name="locale" value={locale} />
          <input type="hidden" name="page" value={(from ?? "").slice(0, 200)} />
          <label className="ms-field"><span className="ms-field__l">{t("feedback.body")}</span>
            <textarea className="ms-input" name="body" rows={7} minLength={5} maxLength={4000} required dir="auto" style={{ inlineSize: "100%", font: "inherit", lineHeight: 1.6 }} /></label>
          <p className="ms-cap">{t("feedback.note")}</p>
          <div><button type="submit" className="ms-btn">{t("feedback.send")}</button></div>
        </form>
      </Panel>
    </>
  );
}
