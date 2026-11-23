import { NextResponse } from "next/server";
import { getSession, type Session } from "./session";

/** Route handlers: a verified session or a 401/403 redirect to the right page. */
/** A Viewer reads records and downloads documents only (Section 3 roles table): every write is refused unless the route is the user's own details. */
export async function requireVerified(req: Request, locale: string, opts: { ownDetails?: boolean } = {}): Promise<{ session: Session } | { response: NextResponse }> {
  const session = await getSession();
  if (!session) return { response: NextResponse.redirect(new URL(`/${locale}/login`, publicBase(req)), 303) };
  if (session.verificationStatus !== "verified") return { response: NextResponse.redirect(new URL(`/${locale}/verification`, publicBase(req)), 303) };
  if (session.role === "viewer" && req.method !== "GET" && req.method !== "HEAD" && !opts.ownDetails) {
    const url = new URL(`/${locale}/dashboard`, publicBase(req)); url.searchParams.set("error", "readOnly");
    return { response: NextResponse.redirect(url, 303) };
  }
  return { session };
}

export function publicBase(req: Request): string {
  const raw = process.env.APP_URL ?? "";
  const m = raw.match(/https?:\/\/[^\s'"<>]+/);
  if (m) { try { new URL("/", m[0]); return m[0].replace(/\/+$/, ""); } catch { /* malformed: fall through to the request's own address */ } }
  const host = req.headers.get("x-forwarded-host") ?? req.headers.get("host");
  return host ? `${req.headers.get("x-forwarded-proto") ?? "https"}://${host}` : req.url;
}

export function go(req: Request, path: string, params?: Record<string, string>, hash?: string): NextResponse {
  const url = new URL(path, publicBase(req));
  for (const [k, v] of Object.entries(params ?? {})) url.searchParams.set(k, v);
  if (hash) url.hash = hash;
  return NextResponse.redirect(url, 303);
}
