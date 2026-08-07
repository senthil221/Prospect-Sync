import type { Metadata } from "next";
import { redirect } from "next/navigation";
import DashboardApp from "./DashboardApp";
import { getAuthorizedUser } from "../lib/auth";

export const metadata: Metadata = {
  title: "Prospect Sync | Master Prospect Database",
  description: "A centralized prospect database for clean client list operations.",
};

export const dynamic = "force-dynamic";

export default async function Home() {
  let user = null;
  try { user = await getAuthorizedUser(); } catch { redirect("/login?setup=required"); }
  if (!user) redirect("/login");
  return <DashboardApp currentUserEmail={user.email ?? "Agency admin"} />;
}
