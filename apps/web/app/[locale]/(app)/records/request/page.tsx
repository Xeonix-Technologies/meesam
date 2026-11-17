import { notFound, redirect } from "next/navigation";
import { isLocale } from "@meesam/i18n";
import { getSession } from "@/lib/session";
import { createDraft, saveDraftStep } from "@/lib/records";
import { applicantDefaults } from "@/lib/filing";

export const dynamic = "force-dynamic";

/** "Request a new filing": opens a draft with the applicant block pre-filled from the account, and goes to step 1. */
export default async function NewFilingRequest({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  const session = await getSession();
  if (!session) redirect(`/${locale}/login`);
  if (session.verificationStatus !== "verified") redirect(`/${locale}/verification`);
  const id = await createDraft(session, "filing");
  await saveDraftStep(session, id, 1, (await applicantDefaults(session)) as never);
  redirect(`/${locale}/records/request/${id}/1`);
}
