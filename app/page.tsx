import type { Metadata } from "next";
import DashboardApp from "./DashboardApp";

export const metadata: Metadata = {
  title: "ProspectHub — Master Prospect Database",
  description: "A centralized prospect database for clean client list operations.",
};

export default function Home() {
  return <DashboardApp />;
}
