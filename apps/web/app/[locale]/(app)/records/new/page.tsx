import { notFound, redirect } from "next/navigation";
import { isLocale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { createDraft } from "@/lib/records";

export const dynamic = "force-dynamic";

/** "Add existing trademark": opens a draft and goes to step 1. */
export default async function NewRecord({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const id = await createDraft(session, "existing");
  redirect(`/${locale}/records/new/${id}/1`);
}
