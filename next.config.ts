import type { NextConfig } from "next";

// Self-hosted Supabase lives on our own domain, so the CSP has to name it.
// Correction, verified empirically 2026-08-25 (build with one value for
// NEXT_PUBLIC_SUPABASE_URL/APP_VERSION, start the standalone server with a
// different one, observe which value the response actually carries): despite
// what this comment used to claim, `headers()` runs once during `next build`
// and is baked into .next/routes-manifest.json. The standalone server does
// NOT call it again at boot or per request, so any process.env read in here
// reflects the build machine, not the deployed one -- which is exactly right
// for NEXT_PUBLIC_SUPABASE_URL, since the Dockerfile's builder stage bakes
// the same value into both this and the client bundle. It is NOT what you
// want for a value that legitimately differs between build and runtime.
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
          // Fixed at build time (see the note above and the Dockerfile's
          // BUILDER stage, where APP_VERSION must be set -- the runner stage
          // is too late, headers() has already run by then). This is what lets
          // the deploy pipeline's smoke test prove the container that answered
          // is the one it just shipped, rather than an old one still running
          // and happening to also return 200. Not sensitive: a commit SHA
          // discloses nothing that isn't already public in the repo.
          { key: "X-App-Version", value: process.env.APP_VERSION || "dev" },
        ],
      },
    ];
  },
};

export default nextConfig;
