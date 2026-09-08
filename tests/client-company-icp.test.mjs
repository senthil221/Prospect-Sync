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
  assert.deepEqual(clientIdleAge("2026-08-28", 30, now), { days: 0, daysRemaining: 30, eligible: false, label: "Eligible in 30 days", nextEligibleDate: "2026-09-27", tone: "fresh" });
  assert.deepEqual(clientIdleAge("2026-08-27", 30, now), { days: 1, daysRemaining: 29, eligible: false, label: "Eligible in 29 days", nextEligibleDate: "2026-09-26", tone: "fresh" });
  assert.equal(clientIdleAge("2026-08-08", 30, now)?.eligible, false);
  assert.equal(clientIdleAge("2026-07-01", 30, now)?.eligible, true);
  assert.equal(clientIdleAge("2026-08-28", 0, now)?.eligible, true, "zero-day cooldown is immediately eligible");
  assert.equal(clientIdleAge("", now), null);
  assert.equal(clientIdleAge("2026-02-30", 30, now), null);
  assert.equal(clientIdleAge("2026-08-30", 30, now)?.daysRemaining, 32);
  assert.equal(clientIdleAge("2026-08-30", 0, now)?.eligible, false);
  assert.equal(clientIdleAge("2026-08-28", Number.NaN, now)?.daysRemaining, 90);
});

test("company ICP verification is isolated by client and supports selected segments", async () => {
  const [migration, membershipMigration, route, companyRoute, companyTable, companyRow, prospectTable, prospectRow, dashboard] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260828204110_client_company_icp_validation.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260829012335_accelerate_company_import_batches.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompaniesWorkspace.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompanyTableRow.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTable.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ProspectTableRow.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
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
  assert.match(route, /set_icp_verified/);
  assert.match(route, /clear_icp_verified/);
  assert.match(route, /push_companies_to_client_v1/);
  assert.match(route, /set_company_icp_verified_v2/);
  assert.match(route, /resolve_selection/);
  assert.match(route, /parseCompanyBulkSelection/);
  assert.match(route, /rawValues\.length > 2_000_000/);
  assert.match(route, /p_client_id: clientId/);
  assert.match(companyRoute, /client_company_icp_validations/);
  assert.match(companyRoute, /icp_validated/);
  assert.match(companyTable, /Mark ICP verified/);
  assert.match(companyTable, /Remove ICP verification/);
  assert.match(companyTable, /Push to Client/);
  assert.match(companyTable, /Client to receive selected companies/);
  assert.match(companyTable, /showSelection = canDelete \|\| Boolean\(clientId\)/);
  assert.match(companyTable, /Select all companies on this page/);
  assert.match(companyTable, /Paste company websites or names/);
  assert.match(companyTable, /Select matching companies/);
  assert.match(companyTable, /setSelectionMode\("explicit"\)/);
  assert.match(companyTable, /manually verified prospects remain eligible/);
  assert.match(companyTable, /allMatching: true/);
  assert.match(companyRow, /company\.icp_validated/);
  assert.match(companyRow, /showSelection \? <td className="select-column"/);
  assert.match(companyRow, /"Verified" : "Not verified"/);
  assert.match(membershipMigration, /create table if not exists public\.client_companies/);
  assert.match(membershipMigration, /primary key \(client_id, company_id\)/);
  assert.match(membershipMigration, /push_companies_to_client_v1/);
  assert.match(membershipMigration, /client_company_workspace_v2/);
  assert.match(membershipMigration, /resolve_company_action_selection_v1/);
  assert.match(membershipMigration, /revoke all on public\.client_companies from anon, authenticated/);
  assert.match(companyRoute, /client_company_workspace_v2/);
  assert.match(dashboard, /clients=\{clients\}/);
  assert.doesNotMatch(prospectTable, /> Mark ICP verified</);
  assert.doesNotMatch(prospectTable, /> Clear verified</);
  assert.doesNotMatch(prospectRow, /onToggleVerified/);
  assert.match(prospectRow, /clientIdleAge\(prospect\.client_date_contacted, clientCooldownDays\)/);
  assert.match(prospectRow, /No contact date/);
});
