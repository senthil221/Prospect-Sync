import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { clientIdleAge } from "../lib/client-idle-age.ts";
import { parseCompanyBulkSelection } from "../lib/company-bulk-selection.ts";

test("mixed company websites and names are normalized for exact bulk selection", () => {
  assert.deepEqual(parseCompanyBulkSelection("https://www.Acme.com/jobs\nGlobex   Corporation\nacme.com\nInitech"), {
    domains: ["acme.com"],
    names: ["globex corporation", "initech"],
    submitted: 4,
    truncated: false,
  });
});

test("prospect idle age is derived from the client-specific Date Contacted", () => {
  const now = new Date("2026-08-28T14:30:00Z");
  assert.deepEqual(clientIdleAge("2026-08-28", now), { days: 0, label: "Contacted today", tone: "fresh" });
  assert.deepEqual(clientIdleAge("2026-08-27", now), { days: 1, label: "1 day ago", tone: "fresh" });
  assert.deepEqual(clientIdleAge("2026-08-08", now), { days: 20, label: "20 days ago", tone: "waiting" });
  assert.deepEqual(clientIdleAge("2026-07-01", now), { days: 58, label: "58 days ago", tone: "idle" });
  assert.deepEqual(clientIdleAge("2026-01-01", now), { days: 239, label: "239 days ago", tone: "stale" });
  assert.equal(clientIdleAge("", now), null);
});

test("company ICP validation is isolated by client and supports selected segments", async () => {
  const [migration, route, companyRoute, companyTable, companyRow, prospectRow] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260828204110_client_company_icp_validation.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompaniesWorkspace.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompanyTableRow.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTableRow.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /primary key \(client_id, company_id\)/);
  assert.match(migration, /enable row level security/);
  assert.match(migration, /revoke all on public\.client_company_icp_validations from anon, authenticated/);
  assert.match(migration, /pi\.client_ids @> array\[p_client_id\]/);
  assert.match(migration, /set_company_icp_validated_v1/);
  assert.match(migration, /resolve_client_company_selection_v1/);
  assert.match(migration, /c\.normalized_domain = any/);
  assert.match(migration, /c\.normalized_name = any/);
  assert.match(migration, /cp\.client_id = p_client_id/);
  assert.match(migration, /inherit_company_icp_validation_v1/);
  assert.match(migration, /before insert or update of client_id, prospect_id, icp_verified/);
  assert.match(migration, /verified_by = 'company:' \|\| p\.company_id/);
  assert.match(migration, /cp\.verified_by = 'company:' \|\| p\.company_id/);
  assert.match(migration, /reindex_scope_v1\(p_prospect_ids => v_prospect_ids\)/);
  assert.match(migration, /'eligibleProspects', cardinality\(v_prospect_ids\)/);
  assert.match(route, /authorizeApi/);
  assert.match(route, /set_icp_validated/);
  assert.match(route, /clear_icp_validated/);
  assert.match(route, /resolve_selection/);
  assert.match(route, /parseCompanyBulkSelection/);
  assert.match(route, /rawValues\.length > 2_000_000/);
  assert.match(route, /p_client_id: clientId/);
  assert.match(companyRoute, /client_company_icp_validations/);
  assert.match(companyRoute, /icp_validated/);
  assert.match(companyTable, /Mark ICP validated/);
  assert.match(companyTable, /Remove ICP validation/);
  assert.match(companyTable, /showSelection = canDelete \|\| Boolean\(clientId\)/);
  assert.match(companyTable, /Select all companies on this page/);
  assert.match(companyTable, /Paste company websites or names/);
  assert.match(companyTable, /Select matching companies/);
  assert.match(companyTable, /setSelectionMode\("explicit"\)/);
  assert.match(companyTable, /manually verified prospects remain eligible/);
  assert.match(companyTable, /allMatching: true/);
  assert.match(companyRow, /company\.icp_validated/);
  assert.match(companyRow, /showSelection \? <td className="select-column"/);
  assert.match(prospectRow, /clientIdleAge\(prospect\.client_date_contacted\)/);
  assert.match(prospectRow, /No contact date/);
});
