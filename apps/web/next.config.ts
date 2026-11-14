import path from "node:path";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  transpilePackages: ["@meesam/i18n", "@meesam/ui"],
  poweredByHeader: false,
  reactStrictMode: true,
  // Standalone output must include the workspace root so pnpm symlinks resolve.
  outputFileTracingRoot: path.join(__dirname, "../../"),
};

export default nextConfig;
