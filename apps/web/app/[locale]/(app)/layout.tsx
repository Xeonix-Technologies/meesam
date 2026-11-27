import Link from "next/link";
import { LangSwitch } from "@/components/LangSwitch";
import { LegalLinks } from "@/components/LegalLinks";
import { anySharedIssue } from "@/lib/publications";
import { activationCounts } from "@/lib/basket";
import { notFound, redirect } from "next/navigation";
import type { ReactNode } from "react";
import { isLocale, pickText, translator, type Locale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { NavLink } from "@/components/NavLink";
import { listNavMarks, type NavMark } from "@/lib/records";
import { staffRoles, type StaffRole } from "@/lib/staff";
import { Logo } from "@/components/Logo";
import { pendingAppointmentCount } from "@/lib/appointments";
import { pendingInstructionCount } from "@/lib/instructions";
import { unreadByRecord } from "@/lib/messages";
import { NavCountsProvider, InstructionsBadge, RequestsBadge, UnreadBadge } from "@/components/NavCounts";

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
  const shared = session.verificationStatus === "verified" ? await anySharedIssue().catch(() => false) : false;
  const noMarks: { marks: NavMark[]; total: number } = { marks: [], total: 0 };
  const { marks, total: markCount } = session.verificationStatus === "verified" ? await listNavMarks(session, NAV_MARKS).catch(() => noMarks) : noMarks;
  const unread = Object.fromEntries((session.verificationStatus === "verified" ? await unreadByRecord(session).catch(() => []) : []).map((u) => [u.record_id, u.n]));
  // the basket shows in the menu only while the account has marks waiting for activation (migration 0104)
  const act = session.verificationStatus === "verified" ? await activationCounts(session).catch(() => ({ waiting: 0, ready: 0, in_basket: 0 })) : { waiting: 0, ready: 0, in_basket: 0 };
  const requests = session.verificationStatus === "verified" ? await pendingAppointmentCount(session).catch(() => 0) : 0;
  const instructions = session.verificationStatus === "verified" ? await pendingInstructionCount(session).catch(() => 0) : 0;
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
          <LangSwitch locale={locale} other={other} label={t("lang.switch")} fallback={`/${other}/${home}`} />
          <form method="post" action="/api/auth/logout">
            <input type="hidden" name="locale" value={locale} />
            <button type="submit" className="ms-btn ms-btn--quiet">{t("nav.logout")}</button>
          </form>
        </div>
      </header>
      <NavCountsProvider initial={{ requests, instructions, unread }}>
      <nav className="ms-nav" aria-label={t("nav.dashboard")}>
        {session.isStaff ? null : <>
        <NavLink href={`/${locale}/dashboard`}>{t("nav.dashboard")}</NavLink>
        {session.verificationStatus === "verified" ? <NavLink href={`/${locale}/alerts`}>{t("nav.alerts")}</NavLink> : null}
        <NavLink href={`/${locale}/records`} exact>{t("portfolio.title")}</NavLink>
        {marks.map((m) => (
          <NavLink key={m.record_id} href={`/${locale}/records/${m.record_id}`} sub>
            <span className="nav-sub__name">{pickText(m.mark_text, locale) || m.registration_no || m.application_no || "—"}</span>
            <UnreadBadge recordId={m.record_id} label={t("dashboard.unreadMessages", { n: "{n}" })}><span className="nav-sub__reg">{m.registry_code}</span></UnreadBadge>
          </NavLink>
        ))}
        {markCount > NAV_MARKS ? <Link href={`/${locale}/records`} className="ms-nav__item nav-sub nav-sub--more">{t("nav.allMarks", { n: markCount })}</Link> : null}
        {act.waiting + act.in_basket > 0 ? <NavLink href={`/${locale}/basket`}><span>{t("basket.title")}</span>{act.in_basket ? <span className="nav-badge">{act.in_basket}</span> : null}</NavLink> : null}
        {session.verificationStatus === "verified" ? (session.accountKind === "agency_office"
          ? <NavLink href={`/${locale}/clients`}><span>{t("nav.clients")}</span>{badge}</NavLink>
          : <NavLink href={`/${locale}/agencies`}><span>{t("nav.agencies")}</span>{badge}</NavLink>) : null}
        {shared ? <NavLink href={`/${locale}/publications`}>{t("publications.title")}</NavLink> : null}
        {/* Founder ruling 19 Nov 2026: owners have Instructions in the menu too (the count is of instructions an office must answer) */}
        {session.verificationStatus === "verified" && !session.isStaff ? <NavLink href={`/${locale}/instructions`}><span>{t("nav.instructions")}</span><InstructionsBadge label={t("dashboard.pendingKinds.instructions", { n: "{n}" })} /></NavLink> : null}
        {session.verificationStatus === "verified" && isAdmin && session.accountKind !== "owner_individual" ? <NavLink href={`/${locale}/users`}>{t("nav.users")}</NavLink> : null}
        </>}
        {isStaff ? <Link href={`/${locale}/admin`} className="ms-nav__item nav-staff">{t("nav.systemAdmin")}</Link> : null}
      </nav>
      </NavCountsProvider>
      <main className="ms-main app-main">{children}<footer className="app-legal"><LegalLinks locale={locale} /><p className="ms-cap tm-note">{t("footer.trademarks")}</p></footer></main>
    </div>
  );
}
