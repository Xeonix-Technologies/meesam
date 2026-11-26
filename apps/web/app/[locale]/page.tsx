import Link from "next/link";
import { formatDate, isLocale, translator, type Locale } from "@meesam/i18n";
import { Logo } from "@/components/Logo";
import { MarkName } from "@/components/ms";
import { CookieNotice } from "@/components/CookieNotice";
import { getSession } from "@/lib/session";

export const dynamic = "force-dynamic";

/**
 * The public home page (Home Page Content v0.1): nine blocks in the order of Section 2, with the copy of
 * Section 3 as written, in both languages. Section 4 rules kept: no registry named above the footer, no search,
 * no price figures (Block 7 is the principle only, ruling of 10 Nov 2026), "Create account" the only filled button.
 */
export default async function Home({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const current: Locale = isLocale(locale) ? locale : "en";
  const other: Locale = current === "en" ? "ar" : "en";
  const t = translator(current);
  const session = await getSession().catch(() => null);
  const stages = Array.from({ length: 9 }, (_, i) => t(`home.life.stages.${i}`));
  const CURRENT = 3;                    // the illustration stands in the opposition period, where the watch matters
  const EVENTS = new Set([6, 8, 9]);    // recordals, challenges and enforcement run beside a registered mark
  const create = `/${current}/create-account`;
  // an illustrative date, always a few weeks ahead of the visitor's day
  const next = formatDate(new Date(Date.now() + 23 * 24 * 3600 * 1000), current);
  const bar = (compact: boolean) => (
    <ol className={compact ? "ms-stagebar ms-stagebar--compact" : "ms-stagebar"} aria-hidden={compact ? true : undefined}>
      {stages.map((s, i) => {
        const n = i + 1;
        const cls = n === CURRENT ? "ms-stage is-current" : EVENTS.has(n) ? "ms-stage is-event" : n < CURRENT ? "ms-stage is-done" : "ms-stage";
        return <li key={n} className={cls} aria-current={!compact && n === CURRENT ? "step" : undefined}><span className="ms-stage__bar" />{compact ? null : <span className="home-stage__name"><span className="ms-stage__n">{n}</span>{s}</span>}</li>;
      })}
    </ol>
  );
  return (
    <main className="home">
      {/* Block 1 — Header */}
      <header className="home-header">
        <Link href={`/${current}`} className="brand-link" aria-label={t("brand")}><Logo height={24} /></Link>
        <nav aria-label={t("brand")}>
          <Link href={`/${other}`} hrefLang={other} lang={other}>{t("lang.switch")}</Link>
          {session ? <Link href={`/${current}/dashboard`}>{t("nav.backToApp")}</Link> : <Link href={`/${current}/login`}>{t("nav.login")}</Link>}
          {session ? null : <Link href={create} className="button">{t("nav.createAccount")}</Link>}
        </nav>
      </header>

      {/* Block 2 — Hero: the mission line, verbatim */}
      <section className="home-hero">
        <div className="home-hero__text">
          <h1>{t("tagline")}</h1>
          <p className="home-sub">{t("home.sub")}</p>
          <div className="home-cta">
            {session ? <Link href={`/${current}/dashboard`} className="button">{t("nav.backToApp")}</Link> : <Link href={create} className="button">{t("nav.createAccount")}</Link>}
            <a href="#how">{t("home.how")}</a>
          </div>
        </div>
        <figure className="home-card" role="img" aria-label={t("home.card.label")}>
          <div className="home-card__top">
            <MarkName runs={["ميسم", "Meesam"]} as="div" />
            <span className="home-badge"><span className="home-badge__dot" />{t("home.card.watch")}</span>
          </div>
          <div className="ms-cap">{t("home.card.stage", { n: CURRENT })} · {stages[CURRENT - 1]}</div>
          {bar(true)}
          <div className="home-card__due"><span className="ms-cap">{t("record.nextDate")}</span><span className="home-chip">{next}</span></div>
        </figure>
      </section>

      {/* Block 3 — Who it is for */}
      <section className="home-sec" aria-labelledby="who">
        <h2 id="who">{t("home.who.title")}</h2>
        <div className="home-grid home-grid--2">
          {(["owners", "agencies"] as const).map((k) => <article key={k} className="home-tile"><h3>{t(`home.who.${k}.title`)}</h3><p>{t(`home.who.${k}.body`)}</p></article>)}
        </div>
      </section>

      {/* Block 4 — What Meesam does */}
      <section className="home-sec" aria-labelledby="does">
        <h2 id="does">{t("home.does.title")}</h2>
        <div className="home-grid home-grid--3">
          {[0, 1, 2, 3, 4].map((i) => <article key={i} className="home-tile"><h3>{t(`home.does.items.${i}.t`)}</h3><p>{t(`home.does.items.${i}.b`)}</p></article>)}
        </div>
      </section>

      {/* Block 5 — A mark's life, in one view: all nine stage names visible */}
      <section className="home-sec" aria-labelledby="life">
        <h2 id="life">{t("home.life.title")}</h2>
        <div className="home-life">
          {bar(false)}
          <div className="home-life__foot">
            <span className="home-life__due"><span className="ms-cap">{t("record.nextDate")}</span><span className="home-chip">{next}</span></span>
            <span className="home-flags">{[6, 8, 9].map((n) => <span key={n} className="home-flag">{t(`record.flagNames.${n}`)}</span>)}</span>
          </div>
        </div>
        <p className="home-caption">{t("home.life.caption")}</p>
      </section>

      {/* Block 6 — How it works */}
      <section className="home-sec" id="how" aria-labelledby="how-title">
        <h2 id="how-title">{t("home.steps.title")}</h2>
        <ol className="home-steps">
          {[0, 1, 2].map((i) => <li key={i}><span className="home-steps__n">{i + 1}</span><div><h3>{t(`home.steps.items.${i}.t`)}</h3><p>{t(`home.steps.items.${i}.b`)}</p></div></li>)}
        </ol>
      </section>

      {/* Block 7 — Pricing: the principle only, no figures (ruling of 10 Nov 2026).
          The figures are on the public Pricing page (Founder ruling R10, 21 Nov 2026). */}
      <section className="home-sec" aria-labelledby="pricing">
        <h2 id="pricing">{t("home.pricing.title")}</h2>
        <p className="home-lead">{t("home.pricing.lead")}</p>
        <p>{t("home.pricing.how")}</p>
        <p><Link href={`/${current}/pricing`}>{t("home.pricing.see")}</Link></p>
      </section>

      {/* Block 8 — What Meesam is not */}
      <section className="home-sec" aria-labelledby="not">
        <h2 id="not">{t("home.not.title")}</h2>
        <p className="home-not">{t("home.not.body")}</p>
      </section>

      {/* Block 9 — Footer, with Help, Feedback and Contact (Founder ruling R11, 21 Nov 2026). */}
      <footer className="home-footer">
        <nav className="legal-links" aria-label={t("legal.nav")}>
          <Link href={`/${current}/legal/terms`}>{t("home.footer.terms")}</Link>
          <Link href={`/${current}/legal/privacy`}>{t("home.footer.privacy")}</Link>
          <Link href={`/${current}/legal/cookies`}>{t("legal.short.cookies")}</Link>
          <Link href={`/${current}/legal/acceptable-use`}>{t("legal.short.acceptable-use")}</Link>
          <Link href={`/${current}/legal/ai-and-watch`}>{t("legal.short.ai-and-watch")}</Link>
          <Link href={`/${current}/help`}>{t("help.title")}</Link>
          <Link href={`/${current}/feedback`}>{t("feedback.title")}</Link>
          <a href="mailto:info@meesam.ae">{t("footer.contact")}</a>
        </nav>
        <div>{t("home.footer.line")}</div>
        {/* Founder, 26 Nov 2026: every page that can show a trademark says whose the trademarks are. */}
        <div>{t("footer.trademarks")}</div>
        <div className="home-domains"><bdi dir="ltr">meesam.ae</bdi> · <bdi dir="ltr">meesam.ai</bdi> · <bdi dir="rtl" lang="ar">ميسم.امارات</bdi></div>
      </footer>
      <CookieNotice text={t("legal.cookieBar")} more={t("legal.short.cookies")} ok={t("legal.cookieOk")} href={`/${current}/legal/cookies`} />
    </main>
  );
}
