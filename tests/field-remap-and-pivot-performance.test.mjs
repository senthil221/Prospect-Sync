import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { requiredPersonImportFields } from "../lib/import-schema.ts";

const migrationUrl = new URL("../supabase/migrations/20260812221326_remap_required_fields_and_fast_company_people.sql", import.meta.url);
const narrowMigrationUrl = new URL("../supabase/migrations/20260812222615_narrow_company_people_pivot_rows.sql", import.meta.url);
const completionMigrationUrl = new URL("../supabase/migrations/20260812223310_complete_company_import_and_refresh_index.sql", import.meta.url);
const completionFixUrl = new URL("../supabase/migrations/20260914090000_company_import_completion_stops_rolling_back.sql", import.meta.url);

test("employee count aliases map into the fixed company import field", async () => {
  const [normalizer, schema, migration] = await Promise.all([
    readFile(new URL("../db/normalize.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/import-schema.ts", import.meta.url), "utf8"),
    readFile(migrationUrl, "utf8"),
  ]);
  assert.match(normalizer, /"employees count"/);
  assert.match(schema, /employeescount: "#employees"/);
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
  assert.match(prospectsRoute, /search_prospect_workspace_v12/);
  assert.match(exportRoute, /search_prospect_export_v5/);
  assert.match(migration, /eligible_companies as materialized/);
  assert.doesNotMatch(migration.slice(migration.indexOf("search_prospect_workspace_v9")), /company_matches_scope_v1/);
  assert.match(narrowMigration, /matched as materialized \(\s+select ps\.id, ps\.created_at/);
  assert.match(narrowMigration, /join public\.prospect_index ps on ps\.id = page\.id/);
});

test("people and company imports enforce the fixed schemas", async () => {
  const [schema, peopleStart, companyStart, companyChunk] = await Promise.all([
    readFile(new URL("../lib/import-schema.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/chunk/route.ts", import.meta.url), "utf8"),
  ]);
  assert.deepEqual(requiredPersonImportFields, []);
  for (const field of ["First Name", "Last Name", "Job Title", "Email", "Mobile Number", "Personal LinkedIn URL", "Company Name", "Website"]) assert.match(schema, new RegExp(`"${field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`));
  for (const field of ["#employees", "Industry", "Website", "Company City", "Company State", "Company Country", "Keywords", "Short Description", "Founded Year", "Technologies", "Total Funding"]) assert.match(schema, new RegExp(`"${field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"`));
  assert.match(peopleStart, /fixedImportColumns/);
  assert.match(peopleStart, /Map at least one supported People field/);
  assert.match(companyStart, /missingCompanyImportFields/);
  // A company row is valid with either a name or a website (not both required).
  assert.match(schema, /companyIdentityFields = \["Company Name", "Website"\]/);
  assert.match(companyChunk, /employeeCountMin/);
  assert.match(companyChunk, /shortDescription/);
  assert.match(companyChunk, /technologies/);
});

// The original of this test asserted that completion rebuilt prospect_index
// inline, against the 20260812223310 migration that introduced it. That is the
// behaviour 20260914090000 removed - one transaction doing the status flip and
// a 131,769-row index rewrite, where a timeout rolled back both and left the
// import unfinishable. Pointed at the historical file the assertions kept
// passing while describing something the database no longer does, so it is
// retargeted rather than deleted: the company columns still have to reach
// prospect_index, just not inside the user's request.
test("completing a company import queues its re-index instead of rebuilding inline", async () => {
  const [route, migration, historical] = await Promise.all([
    readFile(new URL("../app/api/company-imports/complete/route.ts", import.meta.url), "utf8"),
    readFile(completionFixUrl, "utf8"),
    readFile(completionMigrationUrl, "utf8"),
  ]);
  // The behaviour that used to be asserted here, kept as the record of what
  // changed and why the retarget was needed.
  assert.match(historical, /update public\.prospect_index pi/);

  assert.match(route, /complete_company_import_v1/);
  assert.match(route, /reindexCompanyImport/);
  assert.match(migration, /create or replace function public\.queue_company_import_reindex_v1/);
  assert.match(migration, /insert into public\.reindex_backlog/);
  // The status flip must no longer share a transaction with an index rebuild.
  // Asserted against the installed function rather than this file's text: the
  // header quotes the old UPDATE while explaining what it removed, so a naive
  // doesNotMatch on the source would fail on the explanation itself.
  assert.match(migration, /if v_def ilike '%update public\.prospect_index%' then/);
  assert.match(migration, /raise exception 'complete_company_import_v1 still rebuilds prospect_index inline'/);
  // A queue with nothing draining it is a slower way to be stale.
  assert.match(migration, /grant execute on function public\.drain_reindex_backlog\(integer\) to prospect_operator/);
});

test("the operations worker drains the re-index backlog", async () => {
  const worker = await readFile(new URL("../worker/operations-worker.mjs", import.meta.url), "utf8");
  assert.match(worker, /drain_reindex_backlog\(2000\)/);
  assert.match(worker, /runReindexDrain\(\)/);
  assert.match(worker, /event: 'reindex_drain'/);
});

// reindex_scope_v1 resolves p_import_ids through list_rows, a People-import
// concept, so a company import id matches nothing and it returns 0 with no
// error. Anything that "simplifies" the helper back onto reindexScope
// reintroduces a silent no-op, so the warning is pinned by a test.
test("company import re-index does not go through the list-based scope resolver", async () => {
  const reindex = await readFile(new URL("../lib/reindex.ts", import.meta.url), "utf8");
  assert.match(reindex, /export async function reindexCompanyImport/);
  assert.match(reindex, /queue_company_import_reindex_v1/);
  assert.match(reindex, /DO NOT reach for reindexScope\(\{ importIds \}\)/);
});
