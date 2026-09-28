"use client";

import { createRoot } from "react-dom/client";
import { useEffect, useState } from "react";
import EmailVerificationPanel from "../../app/components/EmailVerificationPanel";
import { EmailVerificationDateFilter } from "../../app/ApolloFilterPanel";
import type { ProspectFilter } from "../../lib/types";

type MockRun = Record<string, unknown>;
const requests: Array<Record<string, unknown>> = [];
let createAttempts = 0;
const runs: MockRun[] = [{
  id: "fixture-paused-run", scope: "all", source: "manual", status: "paused",
  total_count: 1200, processed_count: 420, reused_count: 115, skipped_count: 2,
  error_count: 1, force_reverify: false, created_at: "2026-09-28T05:00:00Z",
}];

globalThis.fetch = async (input, init = {}) => {
  const url = String(input);
  if (url === "/api/verifications" && (!init.method || init.method === "GET")) {
    return Response.json({ runs, provider: {
      enabled: true, manually_paused: false, daily_attempts: 18420, daily_limit: 150000,
      worker_configured: true, worker_seen_at: new Date().toISOString(),
    } });
  }
  if (url === "/api/verifications" && init.method === "POST") {
    const body = JSON.parse(String(init.body ?? "{}"));
    requests.push(body); createAttempts += 1;
    (globalThis as typeof globalThis & { __verificationRequests?: unknown }).__verificationRequests = requests;
    if (createAttempts === 1) return Response.json({ preparation: { message: "Preparing the matching companies…" } }, { status: 202 });
    runs.unshift({ id: "fixture-new-run", scope: body.scope, source: "manual", status: "running",
      total_count: 23850, processed_count: 0, reused_count: 0, skipped_count: 0, error_count: 0,
      force_reverify: body.forceReverify, created_at: new Date().toISOString() });
    return Response.json({ run: runs[0] }, { status: 202 });
  }
  if (url.includes("/api/verifications/fixture-paused-run") && init.method === "POST") {
    const body = JSON.parse(String(init.body ?? "{}"));
    const run = runs.find(item => item.id === "fixture-paused-run");
    if (run) run.status = body.action === "continue" ? "running" : body.action === "cancel" ? "cancelled" : "paused";
    return Response.json({ run });
  }
  if (url === "/api/verifications/provider") return Response.json({ ok: true });
  return Response.json({ error: "Unexpected fixture request" }, { status: 500 });
};

function Fixture() {
  const [open, setOpen] = useState(true);
  const [dateFilters, setDateFilters] = useState<ProspectFilter[]>([{
    id: "fixture-date", field: "__work_email_verified_at", operator: "between",
    values: ["2026-09-01T18:30:00.000Z", "2026-09-04T18:30:00.000Z"],
  }]);
  const filters: ProspectFilter[] = [{ id: "fixture-filter", field: "__country", operator: "equals", values: ["India"] }, ...dateFilters];
  useEffect(() => {
    (globalThis as typeof globalThis & { __verificationDateFilters?: ProspectFilter[] }).__verificationDateFilters = dateFilters;
  }, [dateFilters]);
  return <div className="app-shell"><main><div className="content">
    <div className="people-heading"><div><p className="eyebrow">DATABASE WORKSPACE</p><h1>People database</h1><p>Synthetic verification interaction fixture.</p></div></div>
    <button id="verification-launcher" onClick={() => setOpen(true)}>Open email verification</button>
    <section id="verification-date-fixture"><h2>Last Verified fixture</h2><EmailVerificationDateFilter filters={dateFilters} onChange={setDateFilters}/></section>
    {open ? <EmailVerificationPanel open search="VP Sales" filters={filters} companyScope={null} onClose={() => setOpen(false)}/> : null}
  </div></main></div>;
}

createRoot(document.getElementById("root")!).render(<Fixture/>);
