"use client";

import { useState } from "react";
import MobileNav, { type MobileNavItem } from "../../components/MobileNav";

const items: MobileNavItem[] = [
  { id: "overview", label: "Overview", mark: "grid" },
  { id: "prospects", label: "People database", mark: "database" },
  { id: "companies", label: "Companies", mark: "company" },
  { id: "clients", label: "Clients & lists", mark: "clients" },
  { id: "verification", label: "Email verification", mark: "check" },
];

export default function MobileNavFixture() {
  const [section, setSection] = useState("overview");
  return <main id="main-content" tabIndex={-1} style={{ minHeight: "100vh", padding: 24 }}>
    <h1>Navigation fixture</h1>
    <button type="button">Background action</button>
    <p aria-live="polite">Current: {section}</p>
    <MobileNav section={section} items={items} onNavigate={setSection} currentUserEmail="fixture@example.test"/>
  </main>;
}
