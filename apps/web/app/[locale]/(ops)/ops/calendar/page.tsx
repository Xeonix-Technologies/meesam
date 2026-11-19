import { notFound } from "next/navigation";
import { formatDate, isLocale, pickText, translator } from "@meesam/i18n";
import { PageHead, Panel, Table } from "@/components/ms";
import { listSources } from "@/lib/ops";

export const dynamic = "force-dynamic";

/**
 * Operations Console → Release calendar (Section 9A): the release rhythm of every registry and stream, the next
 * expected release, the last actual one and the lateness. A value not yet observed is shown as "to confirm";
 * nothing here is a deadline.
 */
export default async function OpsCalendar({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const t = translator(locale);
  const sources = (await listSources()).filter((s) => typeof s.fetch_spec.inside !== "string");
  const day = (v: string | null) => (v ? formatDate(v, locale) : t("ops.toConfirm"));
  return (
    <>
      <PageHead title={t("ops.calendar.title")} sub={t("ops.calendar.sub")} />
      <Panel>
        <Table head={[t("ops.cols.registry"), t("ops.cols.stream"), t("ops.calendar.frequency"), t("ops.calendar.releaseDay"), t("ops.calendar.localTime"), t("ops.calendar.expectedNext"), t("ops.calendar.lastRelease"), t("ops.calendar.lateness")]}>
          {sources.map((s) => (
            <tr key={s.id}>
              <td title={pickText(s.registry_name, locale)}><b className="num">{s.code}</b></td>
              <td>{t(`ops.streams.${s.stream}`)}</td>
              <td>{s.frequency ? t(`ops.frequency.${s.frequency}`) : t("ops.toConfirm")}</td>
              <td>{s.weekday === null ? t("ops.toConfirm") : t(`ops.weekdays.${s.weekday}`)}</td>
              <td>{s.local_time ? <span className="num">{s.local_time.slice(0, 5)}</span> : t("ops.toConfirm")}<div className="ms-cap" dir="ltr">{s.timezone ?? ""}</div></td>
              <td>{s.active ? day(s.expected_next) : "—"}</td>
              <td>{s.last_release ? formatDate(s.last_release, locale) : "—"}</td>
              <td>{s.days_late ? <span className="flag flag-amber">{t("ops.calendar.late", { n: s.days_late })}</span> : "—"}</td>
            </tr>
          ))}
        </Table>
      </Panel>
      <p className="ms-cap">{t("ops.calendar.notYet")}</p>
    </>
  );
}
