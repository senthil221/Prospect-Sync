import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";
import "./design-system.css";
import "./workspace.css";
import "./components.css";
import "./typography.css";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "prospecthub.local";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.includes("localhost") ? "http" : "https");
  const image = `${protocol}://${host}/og.png`;
  return {
    title: "Prospect Sync | Master Prospect Database",
    description: "A centralized prospect database for clean client list operations.",
    openGraph: { title: "Prospect Sync", description: "One clean source for every prospect.", images: [{ url: image, width: 1536, height: 1024 }] },
    twitter: { card: "summary_large_image", title: "Prospect Sync", description: "One clean source for every prospect.", images: [image] },
  };
}

// Applies the saved theme before first paint. This has to be a plain inline
// script, not next/script: `beforeInteractive` is preloaded but its execution
// does not block paint, which is exactly the flash this exists to prevent.
// The CSP already allows inline scripts (script-src 'self' 'unsafe-inline').
// Default is "light" - dark mode is opt-in, so an OS setting never flips the
// workspace on its own. See app/components/ThemeToggle.tsx.
const themeBootScript = `(function(){try{var c=localStorage.getItem("prospecthub-theme");if(c!=="dark"&&c!=="light"&&c!=="system"){c="light"}if(c==="system"){document.documentElement.removeAttribute("data-theme")}else{document.documentElement.setAttribute("data-theme",c)}}catch(e){document.documentElement.setAttribute("data-theme","light")}})();`;

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en" data-theme="light" suppressHydrationWarning>
    <body>
      <script dangerouslySetInnerHTML={{ __html: themeBootScript }}/>
      {children}
    </body>
  </html>;
}
