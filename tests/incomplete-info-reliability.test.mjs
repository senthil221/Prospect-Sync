import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("Incomplete Info People uses one linked-company predicate and no global pivot", async () => {
  const [clients, migration] = await Promise.all([
    read("../app/components/ClientsPanel.tsx"),
    read("../supabase/migrations/20260925212546_incomplete_company_people_single_pass.sql"),
  ]);

  assert.match(clients, /field: "__incomplete_company_profile", operator: "equals", values: \["true"\]/);
  assert.doesNotMatch(clients, /const incompleteCompanyScope/);
  assert.match(clients, /entity === "people" \? <ClientMasterDatabase[^\n]+active companyScope=\{null\}[^\n]+initialFilters=\{incompletePeopleFilters\}/);

  assert.match(migration, /field_key = '__incomplete_company_profile'/);
  assert.match(migration, /conjuncts := array_append\(conjuncts, 'exists \(select 1 from public\.companies co'/);
  assert.doesNotMatch(migration, /conjuncts := conjuncts \|\| 'exists \(select 1 from public\.companies co'/);
  assert.match(migration, /exists \(select 1 from public\.companies co/);
  assert.match(migration, /co\.id = pi\.company_id/);
  assert.match(migration, /array_to_string\(co\.keywords/);
  assert.match(migration, /co\.short_description/);
  assert.match(migration, /a person without a linked company was classified/);
  assert.match(migration, /v_compiled <> v_matched or v_compiled <> v_expected/);
  assert.match(migration, /prospect_filters_need_company_lookup_v1/);
  assert.match(migration, /bounded first-page count/);
});

test("company-dependent People totals invalidate after enrichment", async () => {
  const migration = await read("../supabase/migrations/20260925212546_incomplete_company_people_single_pass.sql");

  assert.match(migration, /v_has_company_filter boolean := exists/);
  assert.match(migration, /case when v_has_scope or v_has_company_filter/);
  assert.match(migration, /array\['prospect', 'company'\]/);
  assert.match(migration, /search_prospect_workspace_v12/);
  assert.match(migration, /search_prospect_workspace_v13/);
  assert.match(migration, /not \(coalesce\(v_versions, '\{\}'::jsonb\) \? 'company'\)/);
});

test("folder navigator exposes every stable scope with counts and breadcrumbs", async () => {
  const [clients, createRoute, renameRoute] = await Promise.all([
    read("../app/components/ClientsPanel.tsx"),
    read("../app/api/client-folders/route.ts"),
    read("../app/api/client-folders/[id]/route.ts"),
  ]);

  for (const scope of ["All clients", "Named folders", "Unfiled", "Archived"]) {
    assert.ok(clients.includes(scope), `${scope} navigation is missing`);
  }
  assert.match(clients, /aria-label="Client folders"/);
  assert.match(clients, /aria-label="Folder breadcrumb"/);
  assert.match(clients, /aria-current=\{folderSelection === "all" \? "page" : undefined\}/);
  assert.match(clients, /formatNumber\(unfiledClients\.length\)/);
  assert.match(clients, /formatNumber\(archivedClients\.length\)/);
  assert.match(clients, /const \[folderSelection, setFolderSelection\] = useState\("all"\);[\s\S]+if \(!selectedClient\) return <ClientsView/);
  assert.match(clients, /Folders could not be loaded:[^\n]+onRetryFolders/);
  assert.doesNotMatch(clients, /function ClientsView[^\n]+[\s\S]{0,700}useState\("all"\)/);
  assert.match(clients, /Rename folder/);
  assert.match(clients, /method: "PATCH"/);
  assert.match(createRoute, /error\?\.code === "23505"/);
  assert.match(createRoute, /eq\("normalized_name", normalizedName\)\.maybeSingle\(\)/);
  assert.match(renameRoute, /status: 409/);
  assert.match(renameRoute, /code: "folder_name_conflict"/);
});

test("statement timeouts are explicit, non-retryable and non-cacheable", async () => {
  const errors = await read("../lib/api-errors.ts");
  assert.match(errors, /code: "statement_timeout"/);
  assert.match(errors, /retryable: false/);
  assert.match(errors, /"Cache-Control": "no-store"/);
});
