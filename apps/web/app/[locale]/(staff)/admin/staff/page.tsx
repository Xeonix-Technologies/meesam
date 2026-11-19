import { notFound } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { listStaff, STAFF_ROLES } from "@/lib/staff";
import { PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/** System Admin → Staff: who holds a staff role, on which login, and inviting staff to a separate staff login. */
export default async function AdminStaff({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const session = await getSession();
  const staff = await listStaff();
  const customer = staff.filter((s) => !s.separate_login);
  const hidden = (action: string, u: { id: string; email: string; name: string }) => <><input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value={action} /><input type="hidden" name="user_id" value={u.id} /><input type="hidden" name="email" value={u.email} /><input type="hidden" name="name" value={u.name} /></>;
  return (
    <>
      <PageHead title={t("admin.staff.title")} sub={t("admin.staff.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`admin.staff.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`admin.staff.errors.${error}`)}</div></div> : null}
      {customer.length ? <div className="ms-note ms-note--warn" role="status"><div className="ms-note__t">{t("admin.staff.cutover", { n: customer.length })}</div></div> : null}

      <Panel title={`${t("admin.staff.list")} · ${staff.length}`}>
        <Table head={[t("users.cols.name"), t("admin.staff.roles"), t("admin.staff.login"), t("users.cols.status"), t("admin.staff.twoStep"), t("users.cols.lastLogin"), ""]}>
          {staff.map((s) => (
            <tr key={s.id}>
              <td><b>{s.name}</b>{s.id === session?.userId ? <span className="ms-cap"> · {t("users.you")}</span> : null}<div className="ms-cap num" dir="ltr">{s.email}</div></td>
              <td>
                {s.roles.map((r) => (
                  <div key={r} className="role-line">{t(`admin.staff.role.${r}`)}
                    {s.separate_login && s.roles.length > 1 ? (
                      <form method="post" action="/api/admin/staff" className="inline"><input type="hidden" name="locale" value={locale} /><input type="hidden" name="user_id" value={s.id} /><input type="hidden" name="role" value={r} />
                        <button type="submit" name="action" value="role_remove" className="ms-btn ms-btn--sm ms-btn--quiet" aria-label={`${t("admin.staff.roleRemove")}: ${t(`admin.staff.role.${r}`)}`}>{t("admin.staff.roleRemove")}</button></form>
                    ) : null}
                  </div>
                ))}
                {s.separate_login && s.roles.length < STAFF_ROLES.length ? (
                  <form method="post" action="/api/admin/staff" className="inline role-add"><input type="hidden" name="locale" value={locale} /><input type="hidden" name="user_id" value={s.id} />
                    <select name="role" className="ms-input" aria-label={t("admin.staff.roleAdd")}>{STAFF_ROLES.filter((r) => !s.roles.includes(r)).map((r) => <option key={r} value={r}>{t(`admin.staff.role.${r}`)}</option>)}</select>
                    <button type="submit" name="action" value="role_add" className="ms-btn ms-btn--sm ms-btn--quiet">{t("admin.staff.roleAdd")}</button></form>
                ) : null}
              </td>
              <td>{s.separate_login ? t("admin.staff.separate") : <span className="flag flag-amber">{t("admin.staff.customerLogin", { account: pickText(s.account_name, locale) })}</span>}</td>
              <td>{t(`users.status.${s.status}`)}</td>
              <td>{s.totp ? t("admin.staff.app") : t("admin.staff.emailCode")}</td>
              <td>{s.last_login_at ? formatDate(s.last_login_at, locale) : "—"}</td>
              <td>
                {s.separate_login && s.id !== session?.userId ? (
                  <form method="post" action="/api/admin/staff" className="inline">
                    <input type="hidden" name="locale" value={locale} /><input type="hidden" name="user_id" value={s.id} /><input type="hidden" name="email" value={s.email} /><input type="hidden" name="name" value={s.name} />
                    {s.status === "invited" ? <button type="submit" name="action" value="resend" className="ms-btn ms-btn--sm ms-btn--quiet">{t("users.resend")}</button> : null}
                    <button type="submit" name="action" value="remove" className="ms-btn ms-btn--sm ms-btn--danger">{t("users.remove")}</button>
                  </form>
                ) : null}
              </td>
            </tr>
          ))}
        </Table>
      </Panel>

      <Panel title={t("admin.staff.invite")} sub={t("admin.staff.inviteSub")}>
        <form method="post" action="/api/admin/staff" className="form">
          <input type="hidden" name="locale" value={locale} /><input type="hidden" name="action" value="invite" />
          <div className="grid-2">
            <label className="ms-field"><span className="ms-field__l">{t("users.cols.name")}</span><input name="name" className="ms-input" required maxLength={120} /></label>
            <label className="ms-field"><span className="ms-field__l">{t("admin.staff.email")}</span><input name="email" type="email" dir="ltr" className="ms-input" required maxLength={200} /></label>
            <label className="ms-field"><span className="ms-field__l">{t("admin.staff.roles")}</span>
              <select name="role" className="ms-input" defaultValue="system_admin">{STAFF_ROLES.map((r) => <option key={r} value={r}>{t(`admin.staff.role.${r}`)}</option>)}</select></label>
          </div>
          <div className="ms-row" style={{ justifyContent: "flex-end" }}><button type="submit" className="ms-btn">{t("users.sendInvite")}</button></div>
        </form>
      </Panel>
    </>
  );
}
