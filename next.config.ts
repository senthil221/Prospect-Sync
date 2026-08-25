import type { NextConfig } from "next";

// Self-hosted Supabase lives on our own domain, so the CSP has to name it.
// `headers()` runs when the server boots, not at build time, which means this
// reads the deployed value rather than whatever was set on the build machine.
function supabaseOrigin() {
  const configured = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!configured) return "https://*.supabase.co";
  try {
    return new URL(configured).origin;
  } catch {
    return "https://*.supabase.co";
  }
}

const contentSecurityPolicy = [
  "default-src 'self'",
  `connect-src 'self' ${supabaseOrigin()}`,
  // Next.js emits inline bootstrap scripts for App Router pages in production.
  // A nonce requires per-request CSP generation, so static headers require unsafe-inline.
  "script-src 'self' 'unsafe-inline'",
  // read-excel-file delegates larger XLSX archives to a Blob-backed Web Worker.
  "worker-src 'self' blob:",
  "img-src 'self' data:",
  "style-src 'self' 'unsafe-inline'",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join("; ");

const nextConfig: NextConfig = {
  // Emits .next/standalone: a self-contained server with only the traced
  // dependencies, which is what deploy/Dockerfile ships.
  output: "standalone",
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "Content-Security-Policy", value: contentSecurityPolicy },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          {
            key: "Strict-Transport-Security",
            value: "max-age=63072000; includeSubDomains",
          },
          {
            key: "Permissions-Policy",
            value: "camera=(), microphone=(), geolocation=()",
          },
          // Set from the git SHA at image build time (see Dockerfile). This is
          // what lets the deploy pipeline's smoke test prove the container that
          // answered is the one it just shipped, rather than an old one still
          // running and happening to also return 200. Not sensitive: a commit
          // SHA discloses nothing that isn't already public in the repo.
          { key: "X-App-Version", value: process.env.APP_VERSION || "dev" },
        ],
      },
    ];
  },
};

export default nextConfig;
