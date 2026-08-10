import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("Apollo panel exposes the requested main filters and interaction modes", async () => {
  const panel = await readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8");
  assert.match(panel, /id: "__keywords", label: "Keywords"/);
  assert.match(panel, /id: "__title", label: "Job titles"/);
  assert.match(panel, /description: "Job Title is kept separate from Keywords/);
  assert.match(panel, />Include</);
  assert.match(panel, />Exclude</);
  assert.match(panel, /Boolean Search/);
  assert.match(panel, /AND\/OR\/NOT/);
  assert.match(panel, /onPaste/);
  assert.match(panel, /split\(\/\[,;\\n\|\]\//);
  assert.match(panel, /Person location/);
  assert.match(panel, /Company location/);
  assert.match(panel, /Predefined range/);
  assert.match(panel, /Custom range/);
  assert.match(panel, /employees is unknown/);
});

test("new filters are applied globally before pagination and are available to exports", async () => {
  const [migration, route, dashboard] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260810000000_apollo_prospect_filters.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(migration, /add column if not exists keywords text\[\]/);
  assert.match(migration, /employee_count_min integer/);
  assert.match(migration, /company_location/);
  assert.match(migration, /when 'boolean' then/);
  assert.match(migration, /to_tsvector\('simple'/);
  assert.match(migration, /when 'number_ranges' then/);
  assert.match(migration, /custom:%/);
  const viewDefinition = migration.slice(migration.indexOf("create or replace view public.prospect_summaries"), migration.indexOf("create or replace function public.import_prospect_batch_v4"));
  assert.doesNotMatch(viewDefinition, /select p\.\*/);
  assert.ok(viewDefinition.indexOf("co.name as company_name") < viewDefinition.indexOf("p.keywords"), "new view columns must be appended after the existing view contract");
  assert.match(migration, /filtered as materialized/);
  assert.ok(migration.indexOf("filtered as materialized") < migration.indexOf("limit greatest", migration.indexOf("filtered as materialized")));
  assert.match(route, /search_prospect_workspace_v6/);
  assert.match(route, /compileBooleanSearch/);
  assert.match(route, /operator === "number_ranges"/);
  assert.match(route, /header: "Keywords"/);
  assert.match(route, /header: "# Employees"/);
  assert.match(dashboard, /ApolloFilterPanel/);
  assert.match(dashboard, /Company Employee Count/);
});
