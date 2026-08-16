import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { importHeaderSignature, importHeadersMatch } from "../lib/import-resume.ts";

const migrationUrl = new URL("../supabase/migrations/20260816013930_resumable_import_cursors.sql", import.meta.url);

test("matches only the original ordered import header signature", () => {
  const signature = importHeaderSignature(["Name", "Work Email", "Company"]);
  assert.equal(importHeadersMatch(["Name", "Work Email", "Company"], signature), true);
  assert.equal(importHeadersMatch(["Work Email", "Name", "Company"], signature), false);
  assert.equal(importHeadersMatch(["Name", "Email", "Company"], signature), false);
});

test("batch RPCs skip fully committed retries and advance progress transactionally", async () => {
  const migration = await readFile(migrationUrl, "utf8");
  for (const name of ["import_prospect_batch_v5", "import_company_batch_v2"]) {
    const start = migration.indexOf(`create or replace function public.${name}`);
    const end = migration.indexOf("create or replace function public.", start + 1);
    const definition = migration.slice(start, end < 0 ? migration.length : end);
    assert.match(definition, /for update;/);
    assert.match(definition, /if p_row_offset \+ batch_size <= committed_offset then\s+return query select batch_size, 0, 0, 0;/);
    assert.match(definition, /committed_row_offset = greatest\(committed_row_offset, p_row_offset \+ batch_size\)/);
    assert.match(definition, /set statement_timeout = '15s'/);
  }
});

test("chunk routes pass row offsets into both resumable RPCs", async () => {
  const [prospectRoute, companyRoute] = await Promise.all([
    readFile(new URL("../app/api/imports/chunk/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/chunk/route.ts", import.meta.url), "utf8"),
  ]);
  assert.match(prospectRoute, /p_row_offset: normalizedRowOffset/);
  assert.match(companyRoute, /p_row_offset: rowOffset/);
});

test("the imports panel discovers, validates, and cancels interrupted imports", async () => {
  const [listRoute, detailRoute, prospectStart, companyStart, dashboard, importsPanel] = await Promise.all([
    readFile(new URL("../app/api/imports/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/[id]/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/company-imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/ImportsPanel.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(listRoute, /\.eq\("status", "processing"\)/);
  assert.match(listRoute, /committed_row_offset/);
  assert.match(detailRoute, /status: row\.status/);
  assert.match(detailRoute, /committedRowOffset/);
  assert.match(detailRoute, /totalRows/);
  assert.match(prospectStart, /total_rows: totalRows/);
  assert.match(companyStart, /total_rows: totalRows/);
  assert.match(dashboard, /Interrupted — resume from row/);
  assert.match(dashboard, /importHeadersMatch/);
  assert.match(dashboard, /Start a new import instead/);
  assert.match(importsPanel, /Cancel import/);
  assert.match(importsPanel, /cancel: true, kind: cancelImport\.kind/);
  assert.match(detailRoute, /payload\?\.cancel === true/);
  assert.match(detailRoute, /existing\.data\.status !== "processing"/);
  assert.match(detailRoute, /from\("company_imports"\)\.delete\(\)\.eq\("id", id\)\.eq\("status", "processing"\)/);
});
