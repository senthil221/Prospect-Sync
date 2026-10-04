"use client";

import { useState } from "react";
import type { ProspectFilter } from "../../../lib/types";
import { CompanyTable } from "../../components/CompaniesWorkspace";

const company = {
  id: "fixture-company", name: "Fixture Systems", domain: "fixture.test",
  prospect_count: 3, client_count: 1, created_at: "2026-10-04T00:00:00.000Z",
  icp_validated: false,
};
const clients = [
  { id: "fixture-client", name: "Fixture Client", list_count: 0, prospect_count: 3, company_count: 1 },
  { id: "other-client", name: "Other Client", list_count: 0, prospect_count: 0, company_count: 0 },
];
const initialFilters: ProspectFilter[] = [{
  id: "legacy-negative", field: "__company_icp_check", operator: "not_contains",
  values: ["fixture-client|FIT", "fixture-client|NON_FIT"],
}];

const fixtureFetch: typeof fetch = async (input) => {
  const url = String(input);
  if (url.includes("/api/clients/fixture-client/icp-validator")) return Response.json({ labels: [] });
  if (url.includes("/api/clients/fixture-client/icp")) return Response.json({ profiles: [] });
  return Response.json({ error: "Unexpected fixture request" }, { status: 500 });
};
if (typeof window !== "undefined") globalThis.fetch = fixtureFetch;

export default function CompanyWorkspaceFixture() {
  const [filters, setFilters] = useState<ProspectFilter[]>(initialFilters);
  const [page, setPage] = useState(1);
  return <main id="main-content" tabIndex={-1} style={{ minHeight: "100vh", padding: 24 }}>
    <h1>Company workspace fixture</h1>
    <CompanyTable
      companies={[company]} clients={clients} total={1} covered={1} prospectTotal={3}
      page={page} pageSize={50} clientId="fixture-client" filters={filters}
      onSeePeople={() => {}} onFilters={setFilters} onPageChange={setPage}
      onImport={() => {}} allowEntityPivot={false}
    />
  </main>;
}
