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
 * Staff frame (CLAUDE.md rule 11): the Meesam System Admin sits behind the system_admin role and is a separate
 * area from customer accounts. A signed-in user without a staff role gets "not found", not a hint that it exists.
 */
export default async function StaffLayout({ children, params }: { children: ReactNode; params: Promise<{ locale: string }> }) {
  const { locale: raw } = await params;
  if (!isLocale(raw)) notFound();
  const locale: Locale = raw;
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const roles = await staffRoles(session);
  // staff who hold only a watch role work in the Watch Operations Console, a separate area
  if (!roles.includes("system_admin")) { if (roles.includes("watch_lead") || roles.includes("publication_reviewer")) redirect(`/${locale}/ops`); notFound(); }
  const t = translator(locale);
  const other: Locale = locale === "ar" ? "en" : "ar";
  return (
    <div className="app ms-shell">
      <header className="ms-top">
        <Link href={`/${locale}/admin`} className="ms-word brand-link" aria-label={t("admin.title")}><Logo tone="reversed" height={22} /></Link>
        <span className="staff-badge">{t("admin.title")}</span>
        <span className="ms-top__sp" />
        <div className="app-account">
          <span className="ms-acct__btn"><span className="ms-acct__mono" aria-hidden="true">{session.userName.slice(0, 1)}</span><span className="ms-acct__txt"><span className="ms-acct__name">{session.userName}</span><span className="ms-acct__sub">{t("admin.title")}</span></span></span>
          <Link href={`/${other}/admin`} hrefLang={other} lang={other} className="ms-langbtn">{t("lang.switch")}</Link>
          <form method="post" action="/api/auth/logout"><input type="hidden" name="locale" value={locale} /><button type="submit" className="ms-btn ms-btn--quiet">{t("nav.logout")}</button></form>
        </div>
      </header>
      <nav className="ms-nav" aria-label={t("admin.title")}>
        <NavLink href={`/${locale}/admin`} exact>{t("admin.nav.accounts")}</NavLink>
        <NavLink href={`/${locale}/admin/staff`}>{t("admin.nav.staff")}</NavLink>
        <NavLink href={`/${locale}/admin/backups`}>{t("admin.nav.backups")}</NavLink>
        <NavLink href={`/${locale}/admin/feedback`}>{t("admin.nav.feedback")}</NavLink>
        <Link href={`/${locale}/settings`} className="ms-nav__item">{t("admin.nav.myLogin")}</Link>
        {roles.includes("watch_lead") || roles.includes("publication_reviewer") ? <Link href={`/${locale}/ops`} className="ms-nav__item nav-sub--more">{t("ops.title")}</Link> : null}
        {session.isStaff ? null : <Link href={`/${locale}/dashboard`} className="ms-nav__item nav-sub--more">{t("admin.nav.back")}</Link>}
      </nav>
      <main className="ms-main app-main">{children}</main>
    </div>
  );
}
