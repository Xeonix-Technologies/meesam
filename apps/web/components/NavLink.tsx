"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

/** Side-navigation item that marks itself current when the path is under its href. */
export function NavLink({ href, children, exact, sub }: { href: string; children: ReactNode; exact?: boolean; sub?: boolean }) {
  const path = usePathname() ?? "";
  const on = path === href || (!exact && path.startsWith(`${href}/`));
  const cls = `ms-nav__item${sub ? " nav-sub" : ""}${on ? " is-on" : ""}`;
  return <Link href={href} className={cls} aria-current={on ? "page" : undefined}>{children}</Link>;
}
