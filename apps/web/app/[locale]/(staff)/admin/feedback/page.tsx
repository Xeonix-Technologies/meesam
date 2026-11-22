import { notFound } from "next/navigation";
import { formatDateTime, isLocale, pickText, translator } from "@meesam/i18n";
import { listFeedback } from "@/lib/staff";
import { PageHead, Panel, Table } from "@/components/ms";

export const dynamic = "force-dynamic";

/** System Admin → Feedback (ruling R11): what signed-in users wrote in the feedback form, newest first. Reading only. */
export default async function AdminFeedback({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const items = await listFeedback();
  return (
    <>
      <PageHead title={t("admin.feedback.title")} sub={t("admin.feedback.sub")} />
      <Panel title={`${t("admin.feedback.items")} · ${items.length}`}>
        {items.length === 0 ? <p className="ms-sub">{t("admin.feedback.none")}</p> : (
          <div className="ops-table"><Table head={[t("admin.feedback.when"), t("admin.feedback.who"), t("admin.feedback.text")]}>
            {items.map((f) => (
              <tr key={f.id}>
                <td>{formatDateTime(f.created_at, locale)}{f.page ? <div className="ms-cap" dir="ltr">{f.page}</div> : null}</td>
                <td>{f.user_name ?? "—"}<div className="ms-cap">{pickText(f.account_name, locale) || "—"}</div></td>
                <td dir="auto" style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{f.body}</td>
              </tr>
            ))}
          </Table></div>
        )}
      </Panel>
    </>
  );
}
