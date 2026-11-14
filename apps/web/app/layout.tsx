import type { ReactNode } from "react";

// Root layout is intentionally bare; the locale layout owns <html lang dir>.
export default function RootLayout({ children }: { children: ReactNode }) {
  return children;
}
