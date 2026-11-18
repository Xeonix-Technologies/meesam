import { notFound, redirect } from "next/navigation";
import { formatDate, isLocale, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { isAccountAdmin, listUsers, rolesFor } from "@/lib/users";
import { PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/** Account → Users: the administrator invites users and sets their roles (System Description Section 3; Ruled). */
export default async function Users({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string; field?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  if (!isAccountAdmin(session) || session.accountKind === "owner_individual") redirect(`/${locale}/dashboard`);
  const t = translator(locale);
  const users = await listUsers(session);
  const roles = rolesFor(session.accountKind);
  const tone = (s: string) => (s === "active" ? "progress" : s === "invited" ? "registry" : "terminal");
  const hidden = (action: string | null, id: string) => <><input type="hidden" name="locale" value={locale} />{action ? <input type="hidden" name="action" value={action} /> : null}<input type="hidden" name="user_id" value={id} /></>;

  return (
    <>
      <PageHead title={t("users.title")} sub={t("users.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`users.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`users.errors.${error}`)}</div></div> : null}

      <Panel title={`${t("users.list")} · ${users.length}`}>
        <Table head={[t("users.cols.name"), t("users.cols.role"), t("users.cols.status"), t("users.cols.lastLogin"), ""]}>
          {users.map((u) => {
            const self = u.id === session.userId;
            return (
              <tr key={u.id}>
                <td><b>{u.name}</b>{self ? <span className="ms-cap"> · {t("users.you")}</span> : null}<div className="ms-cap num" dir="ltr">{u.email}</div></td>
                <td>
                  <form method="post" action="/api/account/users" className="inline">
                    {hidden("role", u.id)}
                    <select name="role" defaultValue={u.role} className="ms-input" aria-label={t("users.cols.role")}>{(roles.includes(u.role) ? roles : [...roles, u.role]).map((r) => <option key={r} value={r} disabled={!roles.includes(r)}>{t(`users.roles.${r}`)}</option>)}</select>
                    <button type="submit" className="ms-btn ms-btn--sm ms-btn--quiet">{t("common.save")}</button>
                  </form>
                </td>
                <td><span className={`ms-status ms-status--${tone(u.status)}`}><span className="ms-status__mark" aria-hidden="true" />{t(`users.status.${u.status}`)}</span></td>
                <td>{u.last_login_at ? formatDate(u.last_login_at, locale) : "—"}</td>
                <td>
                  {self ? null : (
                    <form method="post" action="/api/account/users" className="inline">
                      {hidden(null, u.id)}
                      {u.status === "invited" ? <button type="submit" name="action" value="resend" className="ms-btn ms-btn--sm ms-btn--quiet">{t("users.resend")}</button> : null}
                      {u.status === "active" ? <button type="submit" name="action" value="suspend" className="ms-btn ms-btn--sm ms-btn--quiet">{t("users.suspend")}</button> : null}
                      {u.status === "suspended" ? <button type="submit" name="action" value="activate" className="ms-btn ms-btn--sm ms-btn--quiet">{t("users.activate")}</button> : null}
                      <button type="submit" name="action" value="remove" className="ms-btn ms-btn--sm ms-btn--danger">{u.status === "invited" ? t("users.cancelInvite") : t("users.remove")}</button>
                    </form>
                  )}
                </td>
              </tr>
            );
          })}
        </Table>
        <p className="ms-cap">{t("users.removeNote")}</p>
      </Panel>

      <Panel title={t("users.invite")} sub={t("users.inviteSub")}>
        <form method="post" action="/api/account/users" className="form">
          <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="invite" />
          <div className="grid-2">
            <label className="ms-field"><span className="ms-field__l">{t("users.cols.name")}</span><input name="name" className="ms-input" required maxLength={120} /></label>
            <label className="ms-field"><span className="ms-field__l">{t("common.email")}</span><input name="email" type="email" dir="ltr" className="ms-input" required maxLength={200} /></label>
            <label className="ms-field"><span className="ms-field__l">{t("users.cols.role")}</span>
              <select name="role" className="ms-input" defaultValue={roles[roles.length - 1]}>{roles.map((r) => <option key={r} value={r}>{t(`users.roles.${r}`)}</option>)}</select></label>
            <label className="ms-field"><span className="ms-field__l">{t("common.language")}</span>
              <select name="user_locale" className="ms-input" defaultValue={locale}><option value="en">English</option><option value="ar">العربية</option></select></label>
          </div>
          <div className="role-notes">{roles.map((r) => <p key={r} className="ms-cap"><b>{t(`users.roles.${r}`)}</b> — {t(`users.can.${r}`)}</p>)}</div>
          <div className="ms-row" style={{ justifyContent: "flex-end" }}><button type="submit" className="ms-btn">{t("users.sendInvite")}</button></div>
        </form>
      </Panel>
    </>
  );
}
