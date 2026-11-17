import { notFound } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { listAdminAccounts, type AdminAccount } from "@/lib/staff";
import { Empty, PageHead, Panel, Table } from "@/components/ms";
import { COUNTRIES } from "@/components/countries";

export const dynamic = "force-dynamic";

/** System Admin → Accounts: the verification queue first, then every account (Staff Services and Pages, Section 4). */
export default async function AdminAccounts({ params, searchParams }: { params: Promise<{ locale: string }>; searchParams: Promise<{ saved?: string; error?: string }> }) {
  const { locale } = await params;
  const { saved, error } = await searchParams;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const accounts = await listAdminAccounts();
  const pending = accounts.filter((a) => a.verification_status === "pending_review");
  const country = (code: string) => { const c = COUNTRIES.find((x) => x.code === code); return c ? (locale === "ar" ? c.ar : c.en) : code; };
  const tone = (s: string) => (s === "verified" ? "progress" : s === "rejected" ? "terminal" : "user");
  const ref = (a: AdminAccount) => (
    <>
      {a.registration_ref ? <div className="num">{a.registration_ref}</div> : null}
      {a.licences?.length ? a.licences.map((l) => <div key={l.registry} className="ms-cap"><span className="num">{l.registry}</span> · <span className="num">{l.ref}</span></div>) : null}
      {!a.registration_ref && !a.licences?.length ? <span className="ms-cap">{t("admin.accounts.noRef")}</span> : null}
    </>
  );
  const users = (a: AdminAccount) => (a.users ?? []).map((u) => <div key={u.id}>{u.name} <span className="ms-cap num">{u.email}</span>{u.status !== "active" ? <span className="ms-cap"> · {u.status}</span> : null}</div>);

  return (
    <>
      <PageHead title={t("admin.accounts.title")} sub={t("admin.accounts.sub")} />
      {saved ? <div className="ms-note ms-note--ok" role="status"><div className="ms-note__t">{t(`admin.accounts.saved.${saved}`)}</div></div> : null}
      {error ? <div className="ms-note ms-note--danger" role="alert"><div className="ms-note__t">{t(`admin.accounts.errors.${error}`)}</div></div> : null}

      <Panel title={`${t("admin.accounts.pending")} · ${pending.length}`}>
        {pending.length === 0 ? <Empty title={t("admin.accounts.pendingNone")} /> : pending.map((a) => (
          <div key={a.id} className="review-card">
            <div className="review-card__head">
              <div><b>{pickText(a.name, locale)}</b>{a.name.ar && a.name.en ? <span className="ms-cap"> · {locale === "ar" ? a.name.en : a.name.ar}</span> : null}
                <div className="ms-cap">{t(`settings.kinds.${a.kind}`)} · {country(a.country)}{a.city ? ` · ${a.city}` : ""} · {formatDate(a.created_at, locale)}</div></div>
              <div>{ref(a)}</div>
            </div>
            <div className="ms-cap">{users(a)}{a.contact?.mobile ? <div className="num">{a.contact.mobile}</div> : null}</div>
            <form method="post" action="/api/admin/accounts/review" className="form">
              <input type="hidden" name="locale" value={locale} /><input type="hidden" name="account_id" value={a.id} />
              <label className="ms-field"><span className="ms-field__l">{t("admin.accounts.note")}</span><input name="note" className="ms-input" maxLength={300} /></label>
              <div className="ms-row" style={{ justifyContent: "flex-end" }}>
                <button type="submit" name="decision" value="reject" className="ms-btn ms-btn--danger">{t("admin.accounts.reject")}</button>
                <button type="submit" name="decision" value="approve" className="ms-btn">{t("admin.accounts.approve")}</button>
              </div>
            </form>
          </div>
        ))}
      </Panel>

      <Panel title={`${t("admin.accounts.all")} · ${accounts.length}`}>
        <Table head={[t("admin.accounts.cols.account"), t("admin.accounts.cols.kind"), t("admin.accounts.cols.country"), t("admin.accounts.cols.reference"), t("admin.accounts.cols.users"), t("admin.accounts.cols.records"), t("admin.accounts.cols.status"), t("admin.accounts.cols.created")]}>
          {accounts.map((a) => (
            <tr key={a.id}>
              <td><b>{pickText(a.name, locale)}</b></td>
              <td>{t(`settings.kinds.${a.kind}`)}</td>
              <td>{country(a.country)}</td>
              <td>{ref(a)}</td>
              <td className="small">{users(a)}</td>
              <td className="num">{a.records}</td>
              <td><span className={`ms-status ms-status--${tone(a.verification_status)}`}><span className="ms-status__mark" aria-hidden="true" />{t(`verification.${a.verification_status}.label`)}</span>{a.review_note ? <div className="ms-cap">{a.review_note}</div> : null}</td>
              <td className="ms-cap">{formatDate(a.created_at, locale)}</td>
            </tr>
          ))}
        </Table>
      </Panel>
    </>
  );
}
