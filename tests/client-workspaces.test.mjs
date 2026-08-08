import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships client-aware duplicates, memberships, and database tabs", async () => {
  const [dashboard, styles, migration, prospectsRoute, companiesRoute, companyProspectsRoute, chunkRoute] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/workspace.css", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260808010000_client_scoped_workspaces.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/[id]/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/chunk/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Uploaded lists/);
  assert.match(dashboard, /Master DB/);
  assert.match(dashboard, /Company DB/);
  assert.match(dashboard, /__lists/);
  assert.match(dashboard, /membership-chips/);
  assert.match(dashboard, /apiResponseCache/);
  assert.match(dashboard, /prefetchApi/);
  assert.match(styles, /\.client-database-tabs/);
  assert.match(styles, /\.membership-chips/);
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
  assert.match(chunkRoute, /import_prospect_batch_v3/);
});
