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
import { parsePastedCompanyTable, parsePastedPeopleTable } from "../lib/paste-table.ts";

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

test("pasted optional edge cells preserve column alignment", () => {
  const people = parsePastedPeopleTable("Email\tPersonal LinkedIn URL\tCity\nana@example.com\t\tDiscard\n\thttps://linkedin.com/in/bea\tDiscard\n\t\t");
  assert.deepEqual(people.rows, [
    ["ana@example.com", "", "Discard"],
    ["", "https://linkedin.com/in/bea", "Discard"],
  ]);
  const columns = fixedImportColumns(people.headers, {}, suggestedPersonImportField, personImportFields);
  const mapped = mapProspect(columns.map(({ field }) => field), columns.map(({ column }) => people.rows[1][column]));
  assert.equal(mapped.identifiers[0].type, "linkedin");
  assert.equal(mapped.identifiers.some(({ type }) => type === "work_email"), false);
  const companies = parsePastedCompanyTable("Company Name\tWebsite\n\t example.com \nAcme\t");
  assert.deepEqual(companies.rows, [["", "example.com"], ["Acme", ""]]);
  const headerless = parsePastedPeopleTable("ana@example.com\t\n\thttps://linkedin.com/in/bea");
  assert.deepEqual(headerless.headers, ["Email", "Personal LinkedIn URL"]);
  assert.deepEqual(headerless.rows, [["ana@example.com", ""], ["", "https://linkedin.com/in/bea"]]);
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

  // Switching has to survive being done repeatedly, which is what makes
  // pivotOrigin a state machine rather than a flag. Each direction restores only
  // when it is the one that pivoted, and clears the origin on the way out - so
  // the next pivot takes a fresh snapshot instead of restoring a stale one, and
  // People -> Companies -> People -> Companies keeps working.
  assert.match(dashboard, /pivotOrigin\.current === "prospects" && peopleBeforePivot\.current/);
  assert.match(dashboard, /pivotOrigin\.current === "companies" && companiesBeforePivot\.current/);
  const restores = dashboard.match(/pivotOrigin\.current = null;/g) ?? [];
  assert.ok(restores.length >= 3, `both pivots and navigate must clear the origin, found ${restores.length}`);
  // Leaving by the nav menu ends the pivot outright. Without this a stale origin
  // makes the next "See People" restore an old workspace instead of pivoting to
  // the company query actually on screen.
  assert.match(dashboard, /const navigate = useCallback[\s\S]{0,220}pivotOrigin\.current = null;[\s\S]{0,120}companiesBeforePivot\.current = null;/);
  assert.doesNotMatch(clients, /key=\{`people:[^`]*companyPeopleScope/);
  assert.doesNotMatch(clients, /key=\{`companies:[^`]*peopleCompanyScope/);
});

test("company export pages safely at 600, 5k and above 5k, then hands large work off", async () => {
  const [route, runner] = await Promise.all([
    read("../app/api/companies/route.ts"), read("../lib/export-runner.ts"),
  ]);
  // Not 500. A page that small was sized against a statement-budget cliff that
  // measurement says is not there: on production the heaviest possible 5,000-row
  // page runs in 1.0s against the function's own 60s, and service_role carries no
  // statement_timeout at all. What a small page does cost is round trips - 839 of
  // them for a full export, each taking a PostgREST connection from a pool of 24
  // with a 10s acquisition timeout.
  assert.match(route, /const exportBatchSize = 2000/);
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
