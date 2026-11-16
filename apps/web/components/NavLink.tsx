"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

/** Side-navigation item that marks itself current when the path is under its href. */
export function NavLink({ href, children }: { href: string; children: ReactNode }) {
  const path = usePathname() ?? "";
  const on = path === href || path.startsWith(`${href}/`);
  return <Link href={href} className={on ? "ms-nav__item is-on" : "ms-nav__item"} aria-current={on ? "page" : undefined}>{children}</Link>;
}
