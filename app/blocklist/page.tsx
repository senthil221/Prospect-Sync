import type { Metadata } from "next";
import BlocklistShareForm from "./share-form";

export const metadata: Metadata = {
  title: "Secure blocklist submission",
  robots: { index: false, follow: false, noarchive: true },
  referrer: "no-referrer",
};

export default function BlocklistSharePage() { return <BlocklistShareForm/>; }
