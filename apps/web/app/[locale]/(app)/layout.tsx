import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import type { ReactNode } from "react";
import { isLocale, pickText, translator, type Locale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { NavLink } from "@/components/NavLink";
import { listPortfolio } from "@/lib/records";
import { staffRoles, type StaffRole } from "@/lib/staff";
import { Logo } from "@/components/Logo";
import { pendingAppointmentCount } from "@/lib/appointments";
import { unreadByRecord } from "@/lib/messages";
import { NavCountsProvider, RequestsBadge, UnreadBadge } from "@/components/NavCounts";

export const dynamic = "force-dynamic";

/** Signed-in frame. Login first; nothing is reachable before authentication (Ruled). */
const NAV_MARKS = 15;

export default async function AppLayout({ children, params }: { children: ReactNode; params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  const t = translator(locale);
  const other: Locale = locale === "en" ? "ar" : "en";
  const home = session.verificationStatus === "verified" ? "dashboard" : "verification";
  const isAdmin = session.role === "company_admin" || session.role === "agency_admin";
  const acc = pickText(session.accountName, locale);
  // the account's trademarks sit under Portfolio so a record is one click away from any page
  const isStaff = (await staffRoles(session).catch((): StaffRole[] => [])).includes("system_admin");
  const marks = session.verificationStatus === "verified" ? await listPortfolio(session).catch(() => []) : [];
  const unread = Object.fromEntries((session.verificationStatus === "verified" ? await unreadByRecord(session).catch(() => []) : []).map((u) => [u.record_id, u.n]));
  const requests = session.verificationStatus === "verified" ? await pendingAppointmentCount(session).catch(() => 0) : 0;
  const badge = <RequestsBadge label={t("dashboard.pendingKinds.appointments", { n: "{n}" })} />;
  return (
    <div className="app ms-shell">
      <header className="ms-top">
        <Link href={`/${locale}`} className="ms-word brand-link" aria-label={t("brand")}><Logo tone="reversed" height={22} /></Link>
        <span className="ms-top__sp" />
        <div className="app-account">
          {/* Owner (individual): the person's name opens the account. Company or agency: the account name opens the
              account details (administrators only); the person's name opens their own details. */}
          {session.accountKind === "owner_individual" ? (
            <Link href={`/${locale}/settings`} className="ms-acct__btn" title={t("settings.title")}>
              <span className="ms-acct__mono" aria-hidden="true">{session.userName.slice(0, 1)}</span>
              <span className="ms-acct__txt"><span className="ms-acct__name">{session.userName}</span></span>
            </Link>
          ) : (
            <span className="ms-acct__btn">
              {session.logoKey ? <img className="ms-acct__logo" src="/api/account/logo" alt="" /> : <span className="ms-acct__mono" aria-hidden="true">{(acc || session.userName).slice(0, 1)}</span>}
              <span className="ms-acct__txt">
                <span className="ms-acct__name">{isAdmin ? <Link href={`/${locale}/settings`} title={t("settings.account")}>{acc}</Link> : acc}</span>
                <span className="ms-acct__sub"><Link href={`/${locale}/settings#you`} title={session.email}>{session.userName}</Link></span>
              </span>
            </span>
          )}
          <Link href={`/${other}/${home}`} hrefLang={other} lang={other} className="ms-langbtn">{t("lang.switch")}</Link>
          <form method="post" action="/api/auth/logout">
            <input type="hidden" name="locale" value={locale} />
            <button type="submit" className="ms-btn ms-btn--quiet">{t("nav.logout")}</button>
          </form>
        </div>
      </header>
      <NavCountsProvider initial={{ requests, unread }}>
      <nav className="ms-nav" aria-label={t("nav.dashboard")}>
        <NavLink href={`/${locale}/dashboard`}>{t("nav.dashboard")}</NavLink>
        <NavLink href={`/${locale}/records`} exact>{t("portfolio.title")}</NavLink>
        {marks.slice(0, NAV_MARKS).map((m) => (
          <NavLink key={m.record_id} href={`/${locale}/records/${m.record_id}`} sub>
            <span className="nav-sub__name">{pickText(m.mark_text, locale) || m.registration_no || m.application_no || "—"}</span>
            <UnreadBadge recordId={m.record_id} label={t("dashboard.unreadMessages", { n: "{n}" })}><span className="nav-sub__reg">{m.registry_code}</span></UnreadBadge>
          </NavLink>
        ))}
        {marks.length > NAV_MARKS ? <Link href={`/${locale}/records`} className="ms-nav__item nav-sub nav-sub--more">{t("nav.allMarks", { n: marks.length })}</Link> : null}
        {session.verificationStatus === "verified" ? (session.accountKind === "agency_office"
          ? <NavLink href={`/${locale}/clients`}><span>{t("nav.clients")}</span>{badge}</NavLink>
          : <NavLink href={`/${locale}/agencies`}><span>{t("nav.agencies")}</span>{badge}</NavLink>) : null}
        {session.verificationStatus === "verified" && isAdmin && session.accountKind !== "owner_individual" ? <NavLink href={`/${locale}/users`}>{t("nav.users")}</NavLink> : null}
        {isStaff ? <Link href={`/${locale}/admin`} className="ms-nav__item nav-staff">{t("nav.systemAdmin")}</Link> : null}
      </nav>
      </NavCountsProvider>
      <main className="ms-main app-main">{children}</main>
    </div>
  );
}
