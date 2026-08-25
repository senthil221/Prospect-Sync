import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships client-aware duplicates, memberships, and database tabs", async () => {
  const [dashboard, clientsPanel, styles, componentStyles, migration, prospectsRoute, companiesRoute, companyProspectsRoute, chunkRoute] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ClientsPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/workspace.css", import.meta.url), "utf8"),
    readFile(new URL("../app/components.css", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260808010000_client_scoped_workspaces.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/[id]/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/import-batch.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Uploaded lists/);
  assert.match(dashboard, /Master DB/);
  assert.match(dashboard, /Company DB/);
  assert.match(dashboard, /__lists/);
  assert.match(dashboard, /membership-chips/);
  assert.match(dashboard, /prospectMembershipItems/);
  assert.match(dashboard, /\+\{hiddenCount\} more/);
  assert.match(dashboard, /Tag count verified/);
  assert.match(dashboard, /drawer-membership-list/);
  assert.match(dashboard, /apiResponseCache/);
  assert.match(dashboard, /prefetchApi/);
  assert.match(dashboard, /prefetchSection/);
  // The client database tabs are now the shared segmented control rather than a
  // bespoke strip: assert the component ships and that the panel actually uses it.
  assert.match(componentStyles, /\.ds-tabs-segmented/);
  assert.match(clientsPanel, /variant="segmented"/);
  assert.match(styles, /\.membership-chips/);
  assert.match(styles, /\.drawer-memberships/);
  assert.match(migration, /create or replace view public\.prospect_summaries/);
  assert.match(migration, /list_memberships/);
  assert.match(migration, /search_prospect_workspace_v4/);
  assert.match(migration, /client_company_workspace/);
  assert.match(migration, /client_company_prospects/);
  assert.match(migration, /other_list\.client_id <> current_list\.client_id/);
  assert.match(migration, /Same person found in different clients/);
  assert.match(prospectsRoute, /p_client_id/);
  assert.match(companiesRoute, /client_company_workspace/);
  assert.match(companyProspectsRoute, /client_company_prospects/);
  assert.match(chunkRoute, /import_prospect_batch_v5/);
});

test("ships the database and API performance hardening", async () => {
  const [migration, dashboardRoute, prospectsRoute] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260808030000_performance_hardening.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/dashboard/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /idx_imports_client_id/);
  assert.match(migration, /idx_imports_list_id/);
  assert.match(migration, /idx_memberships_import_id/);
  assert.match(migration, /create or replace function public\.dashboard_workspace/);
  assert.match(migration, /revoke execute on function public\.rls_auto_enable/);
  assert.match(dashboardRoute, /rpc\("dashboard_workspace"\)/);
  assert.match(prospectsRoute, /includeFields/);
  assert.match(prospectsRoute, /Promise\.all\(\[workspaceRequest, fieldsRequest\]\)/);
});
