import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";
import "./workspace.css";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "prospecthub.local";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.includes("localhost") ? "http" : "https");
  const image = `${protocol}://${host}/og.png`;
  return {
    title: "Prospect Sync — Master Prospect Database",
    description: "A centralized prospect database for clean client list operations.",
    openGraph: { title: "Prospect Sync", description: "One clean source for every prospect.", images: [{ url: image, width: 1536, height: 1024 }] },
    twitter: { card: "summary_large_image", title: "Prospect Sync", description: "One clean source for every prospect.", images: [image] },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
