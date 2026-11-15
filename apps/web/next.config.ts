import path from "node:path";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  transpilePackages: ["@meesam/i18n", "@meesam/ui", "@meesam/db"],
  poweredByHeader: false,
  reactStrictMode: true,
  // Standalone output must include the workspace root so pnpm symlinks resolve.
  outputFileTracingRoot: path.join(__dirname, "../../"),
  // Workspace packages import with ".js" extensions (NodeNext for the worker); map them to .ts here.
  webpack: (config) => {
    config.resolve.extensionAlias = { ".js": [".ts", ".tsx", ".js"], ".mjs": [".mts", ".mjs"] };
    return config;
  },
  serverExternalPackages: ["postgres"],
};

export default nextConfig;
