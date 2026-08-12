import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const migrationUrl = new URL("../supabase/migrations/20260812221326_remap_required_fields_and_fast_company_people.sql", import.meta.url);
const narrowMigrationUrl = new URL("../supabase/migrations/20260812222615_narrow_company_people_pivot_rows.sql", import.meta.url);
const completionMigrationUrl = new URL("../supabase/migrations/20260812223310_complete_company_import_and_refresh_index.sql", import.meta.url);

test("employee count aliases map Employees Count into the canonical numeric filter", async () => {
  const [normalizer, schema, migration] = await Promise.all([
    readFile(new URL("../db/normalize.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/import-schema.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
  ]);
  assert.match(normalizer, /"employees count"/);
  assert.match(schema, /employeescount: "Company Employee Count"/);
  assert.match(migration, /'employeescount'/);
  assert.match(migration, /employee_count_min = coalesce/);
});

test("existing person geography backfills canonical company location fields", async () => {
  const migration = await readFile(migrationUrl, "utf8");
  assert.match(migration, /most common, most complete person location/);
  assert.match(migration, /update public\.companies c set\s+location =/);
  assert.match(migration, /update public\.prospect_index pi set/);
});

test("Company to People pivot computes eligible companies once", async () => {
  const [prospectsRoute, exportRoute, migration, narrowMigration] = await Promise.all([
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/export/route.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
    readFile(narrowMigrationUrl, "utf8"),
  ]);
  assert.match(prospectsRoute, /search_prospect_workspace_v10/);
  assert.match(exportRoute, /search_prospect_export_v4/);
  assert.match(migration, /eligible_companies as materialized/);
  assert.doesNotMatch(migration.slice(migration.indexOf("search_prospect_workspace_v9")), /company_matches_scope_v1/);
  assert.match(narrowMigration, /matched as materialized \(\s+select ps\.id, ps\.created_at/);
  assert.match(narrowMigration, /join public\.prospect_index ps on ps\.id = page\.id/);
});

test("people and company imports require the approved schemas", async () => {
  const [schema, peopleStart, companyStart, companyChunk] = await Promise.all([
    readFile(new URL("../lib/import-schema.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/chunk/route.ts", import.meta.url), "utf8"),
  ]);
  for (const field of ["Name", "Company Name", "Email", "Personal LinkedIn URL", "Job Title", "Seniority", "Departments", "Sub Departments"]) assert.match(schema, new RegExp(`"${field}"`));
  for (const field of ["#employees", "Industry", "Website", "Company City", "Company State", "Company Country", "Keywords", "Short Description", "Founded Year", "Technologies", "Total Funding"]) assert.match(schema, new RegExp(`"${field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`));
  assert.match(peopleStart, /missingRequiredFields/);
  assert.match(companyStart, /missingRequiredFields/);
  assert.match(companyChunk, /employeeCountMin/);
  assert.match(companyChunk, /shortDescription/);
  assert.match(companyChunk, /technologies/);
});

test("completing a company import refreshes company-derived prospect filters", async () => {
  const [route, migration] = await Promise.all([
    readFile(new URL("../app/api/company-imports/complete/route.ts", import.meta.url), "utf8"),
    readFile(completionMigrationUrl, "utf8"),
  ]);
  assert.match(route, /complete_company_import_v1/);
  assert.match(migration, /update public\.prospect_index pi/);
  assert.match(migration, /employee_count_min = c\.employee_count_min/);
  assert.match(migration, /company_location = coalesce\(c\.location, ''\)/);
});
