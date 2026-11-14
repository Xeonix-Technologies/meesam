import { NextResponse, type NextRequest } from "next/server";
import { defaultLocale, isLocale } from "@meesam/i18n";

/** Locale lives in the first path segment: /en/..., /ar/... (routing-level i18n). */
export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const first = pathname.split("/")[1];
  if (isLocale(first)) return NextResponse.next();
  const url = request.nextUrl.clone();
  url.pathname = `/${defaultLocale}${pathname === "/" ? "" : pathname}`;
  return NextResponse.redirect(url);
}

export const config = {
  matcher: ["/((?!api|_next|favicon.ico|robots.txt|.*\\..*).*)"],
};
