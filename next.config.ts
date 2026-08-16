import type { NextConfig } from "next";

const contentSecurityPolicy = [
  "default-src 'self'",
  "connect-src 'self' https://*.supabase.co",
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
  /* config options here */
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
        ],
      },
    ];
  },
};

export default nextConfig;
