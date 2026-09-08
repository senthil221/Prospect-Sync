import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { mapProspect } from "../db/normalize.ts";
import { estimatedCompanyBytesPerRow } from "../lib/company-export.ts";
import { planExport } from "../lib/export-plan.ts";
import {
  companyImportFields, fixedImportColumns, personImportFields,
  suggestedCompanyImportField, suggestedPersonImportField,
} from "../lib/import-schema.ts";
import { parsePastedPeopleTable } from "../lib/paste-table.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("fixed import contracts discard unsupported source columns", () => {
  assert.deepEqual([...personImportFields], [
    "First Name", "Last Name", "Job Title", "Email", "Mobile Number",
    "Personal LinkedIn URL", "Company Name", "Website",
  ]);
  assert.deepEqual([...companyImportFields], [
    "Company Name", "Website", "Industry", "Keywords", "Short Description",
    "Founded Year", "#employees", "Company City", "Company State",
    "Company Country", "Technologies", "Total Funding",
  ]);

  const people = fixedImportColumns(
    ["Email Address", "Favorite color", "LinkedIn URL", "Secret note"],
    {}, suggestedPersonImportField, personImportFields,
  );
  assert.deepEqual(people.map(({ field }) => field), ["Email", "Personal LinkedIn URL"]);
  const companies = fixedImportColumns(
    ["Account Name", "Revenue", "Domain", "Office City"],
    {}, suggestedCompanyImportField, companyImportFields,
  );
  assert.deepEqual(companies.map(({ field }) => field), ["Company Name", "Website"]);
});

test("People paste accepts email-only and LinkedIn-only identities", () => {
  const email = parsePastedPeopleTable("ana@example.com\nbea@example.com");
  assert.deepEqual(email.headers, ["Email"]);
  assert.equal(mapProspect(email.headers, email.rows[0]).identifiers[0].type, "work_email");

  const linkedin = parsePastedPeopleTable("https://linkedin.com/in/ana\nhttps://linkedin.com/in/bea");
  assert.deepEqual(linkedin.headers, ["Personal LinkedIn URL"]);
  assert.equal(mapProspect(linkedin.headers, linkedin.rows[0]).identifiers[0].type, "linkedin");

  const withUnsupportedHeader = parsePastedPeopleTable("Email\tFavorite color\nana@example.com\tgreen");
  assert.equal(withUnsupportedHeader.inferredHeaders, false);
  assert.deepEqual(withUnsupportedHeader.rows, [["ana@example.com", "green"]]);
});

test("import APIs sanitize raw payloads and report rows with no identity", async () => {
  const [peopleChunk, peopleWorker, companyChunk, migration] = await Promise.all([
    read("../lib/import-batch.ts"), read("../worker/import-worker.mjs"),
    read("../app/api/company-imports/chunk/route.ts"),
    read("../supabase/migrations/20260908141654_fixed_imports_icp_cooldown_and_classifier.sql"),
  ]);
  for (const source of [peopleChunk, peopleWorker]) {
    assert.match(source, /fixedImport|personImportFields/);
    assert.match(source, /identif/i);
  }
  assert.match(companyChunk, /rejectedRows/);
  assert.match(companyChunk, /company name nor website/);
  assert.match(migration, /p_apply boolean default false/);
  assert.match(migration, /p_entity not in \('prospect', 'company', 'list_row', 'membership', 'catalog'\)/);
  assert.match(migration, /public\.list_rows/);
  assert.match(migration, /public\.list_memberships/);
  assert.match(migration, /p_key in \('_enriched_from', '_enriched_at'\)/);
  assert.doesNotMatch(migration, /disable row level security/i);
});

test("People and Company pivots retain a reversible workspace snapshot", async () => {
  const [dashboard, clients] = await Promise.all([
    read("../app/DashboardApp.tsx"), read("../app/components/ClientsPanel.tsx"),
  ]);
  assert.match(dashboard, /peopleBeforePivot/);
  assert.match(dashboard, /companiesBeforePivot/);
  assert.match(dashboard, /setProspectSort\(previous\.sort\)/);
  assert.match(dashboard, /setCompanyFilters\(previous\.filters\)/);
  assert.doesNotMatch(clients, /key=\{`people:[^`]*companyPeopleScope/);
  assert.doesNotMatch(clients, /key=\{`companies:[^`]*peopleCompanyScope/);
});

test("company export pages safely at 600, 5k and above 5k, then hands large work off", async () => {
  const [route, runner] = await Promise.all([
    read("../app/api/companies/route.ts"), read("../lib/export-runner.ts"),
  ]);
  assert.match(route, /const exportBatchSize = 500/);
  assert.match(route, /invalid first page; no file was created/);
  assert.match(route, /AbortSignal\.timeout\(120_000\)/);
  assert.match(runner, /let writable: WritableLike \| null = null/);
  assert.match(runner, /await sink\.abort\(\)/);

  const bytesPerRow = estimatedCompanyBytesPerRow([], ["__company_name", "__website"]);
  for (const rows of [600, 5000, 6001]) assert.equal(planExport({ bytesPerRow, rows }).mode, "direct");
  assert.equal(planExport({ bytesPerRow, rows: 50001 }).mode, "background");
});

test("ICP quick filters and classifier checkpoints are server-side and resumable", async () => {
  const [people, companies, migration, maintenance, classifier] = await Promise.all([
    read("../app/components/ProspectTable.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
    read("../supabase/migrations/20260908141654_fixed_imports_icp_cooldown_and_classifier.sql"),
    read("../deploy/scripts/maintenance.sh"),
    read("../app/api/prospects/classify/route.ts"),
  ]);
  for (const source of [people, companies]) {
    assert.match(source, /ICP Verified/);
    assert.match(source, /ICP Unverified/);
    assert.match(source, /setPage|onPageChange/);
  }
  assert.match(migration, /when '__icp_verified'/);
  assert.match(migration, /when '__company_icp_verified'/);
  assert.match(migration, /pg_try_advisory_xact_lock/);
  assert.match(migration, /remaining bigint/);
  assert.match(maintenance, /run_title_classification_batch_v2\(1000\)/);
  assert.match(classifier, /Classification made no progress/);
});
