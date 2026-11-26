import { sql } from "drizzle-orm";
import { withRole } from "@meesam/db";
import type { I18nText } from "@meesam/db";
import { db } from "./db";

/**
 * Publications shown to signed-in accounts (Founder, 26 Nov 2026; migration 0100). Only the issues of a source the
 * watch operations lead has switched on, read through database functions that say so; a signed-in account sees
 * the list and may download each file exactly as the registry published it. Not a search and not a public page.
 */
export interface SharedIssue {
  id: string; registry_code: string; registry_name: I18nText; stream: string; issue_no: string; published_on: string | null;
  size_bytes: string | null; container: string; location: string | null; marks: number; notices: number;
}
const rows = <T>(r: unknown) => r as unknown as T[];
export const listSharedIssues = async () => rows<SharedIssue>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`
  SELECT id, registry_code, registry_name, stream, issue_no, published_on::text, size_bytes::text, container, location, marks, notices FROM watch.fn_shared_issues()`)));
export const anySharedIssue = async () => rows<{ any: boolean }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`
  SELECT EXISTS (SELECT 1 FROM watch.fn_shared_issues()) AS any`)))[0]?.any ?? false;
export const sharedIssueFile = async (id: string) => rows<{ object_key: string; container: string; registry_code: string; issue_no: string }>(await withRole(db(), "meesam_app", (tx) => tx.execute(sql`
  SELECT object_key, container, registry_code, issue_no FROM watch.fn_shared_issue_file(${id}::uuid)`)))[0] ?? null;
