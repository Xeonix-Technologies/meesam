import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import type { ReactNode } from "react";
import { isLocale, translator, type Locale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { staffRoles } from "@/lib/staff";
import { NavLink } from "@/components/NavLink";
import { Logo } from "@/components/Logo";

export const dynamic = "force-dynamic";

/**
 * Watch Operations Console frame (MSM-PRD-02 Section 9A; CLAUDE.md rule 11): a staff area of its own, apart from
 * the Meesam System Admin, for the watch operations lead (manage) and the publication reviewer (verify).
 * Anyone else gets "not found".
 */
export default async function OpsLayout({ children, params }: { children: ReactNode; params: Promise<{ locale: string }> }) {
  const { locale: raw } = await params;
  if (!isLocale(raw)) notFound();
  const locale: Locale = raw;
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const roles = await staffRoles(session);
  if (!roles.includes("watch_lead") && !roles.includes("publication_reviewer")) notFound();
  const t = translator(locale);
  const other: Locale = locale === "ar" ? "en" : "ar";
  return (
    <div className="app ms-shell">
      <header className="ms-top">
        <Link href={`/${locale}/ops`} className="ms-word brand-link" aria-label={t("ops.title")}><Logo tone="reversed" height={22} /></Link>
        <span className="staff-badge">{t("ops.title")}</span>
        <span className="ms-top__sp" />
        <div className="app-account">
          <span className="ms-acct__btn"><span className="ms-acct__mono" aria-hidden="true">{session.userName.slice(0, 1)}</span><span className="ms-acct__txt"><span className="ms-acct__name">{session.userName}</span><span className="ms-acct__sub">{roles.filter((r) => r !== "system_admin").map((r) => t(`admin.staff.role.${r}`)).join(" · ")}</span></span></span>
          <Link href={`/${other}/ops`} hrefLang={other} lang={other} className="ms-langbtn">{t("lang.switch")}</Link>
          <form method="post" action="/api/auth/logout"><input type="hidden" name="locale" value={locale} /><button type="submit" className="ms-btn ms-btn--quiet">{t("nav.logout")}</button></form>
        </div>
      </header>
      <nav className="ms-nav" aria-label={t("ops.title")}>
        <NavLink href={`/${locale}/ops`} exact>{t("ops.nav.registries")}</NavLink>
        <NavLink href={`/${locale}/ops/calendar`}>{t("ops.nav.calendar")}</NavLink>
        <NavLink href={`/${locale}/ops/inbox`}>{t("ops.nav.inbox")}</NavLink>
        <NavLink href={`/${locale}/ops/incidents`}>{t("ops.nav.incidents")}</NavLink>
        <NavLink href={`/${locale}/ops/quality`}>{t("ops.nav.quality")}</NavLink>
        <Link href={`/${locale}/settings`} className="ms-nav__item">{t("admin.nav.myLogin")}</Link>
        {roles.includes("system_admin") ? <Link href={`/${locale}/admin`} className="ms-nav__item nav-sub--more">{t("admin.title")}</Link> : null}
      </nav>
      <main className="ms-main app-main">{children}</main>
    </div>
  );
}
