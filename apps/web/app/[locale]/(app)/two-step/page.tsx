import { notFound, redirect } from "next/navigation";
import { isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { askTwoStep, myTwoFactor } from "@/lib/twofactor";

export const dynamic = "force-dynamic";

/**
 * Asked once, after signing in (Founder ruling 23 Nov 2026): whether to use two-step sign-in and where the code
 * comes from. A login whose second step is always on (staff) is only asked "by e-mail or by app".
 */
export default async function TwoStepAsk({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const home = `/${locale}/${session.verificationStatus === "verified" ? "dashboard" : "verification"}`;
  if (session.verificationStatus !== "verified" || !(await askTwoStep(session.userId))) redirect(home);
  const tf = await myTwoFactor(session);
  const t = translator(locale);
  const Choice = ({ how, title, note, primary }: { how: string; title: string; note: string; primary?: boolean }) => (
    <form method="post" action="/api/account/twofactor" className="tf-choice">
      <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="choose" /><input type="hidden" name="how" value={how} />
      <div><b>{title}</b><p className="muted small">{note}</p></div>
      <button className={primary ? "button" : "button-secondary"} type="submit">{title}</button>
    </form>
  );
  return (
    <div className="stack">
      <h1>{t("settings.twofactor.ask.title")}</h1>
      <section className="card">
        <p>{session.isStaff || tf.required ? t("settings.twofactor.ask.leadOn") : t("settings.twofactor.ask.leadOff")}</p>
        <Choice how="app" title={t("settings.twofactor.ask.app")} note={t("settings.twofactor.ask.appNote")} primary />
        <Choice how="email" title={t("settings.twofactor.ask.email")} note={t("settings.twofactor.ask.emailNote", { email: session.email })} />
        {!session.isStaff ? <Choice how="none" title={t("settings.twofactor.ask.none")} note={t("settings.twofactor.ask.noneNote")} /> : null}
        <p className="muted small">{t("settings.twofactor.ask.once")}</p>
      </section>
    </div>
  );
}
