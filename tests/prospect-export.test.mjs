import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { csvDocument } from "../lib/csv.ts";

test("creates Excel-friendly CSV without formula injection", () => {
  const csv = csvDocument(["Name", "Notes"], [
    ["Ada, Inc.", "Said \"hello\"\nagain"],
    ["=HYPERLINK(\"https://example.com\")", "+1-555-0100"],
  ]);
  assert.ok(csv.startsWith("\uFEFF"));
  assert.match(csv, /"Ada, Inc\."/);
  assert.match(csv, /"Said ""hello""\nagain"/);
  assert.match(csv, /"'=HYPERLINK/);
  assert.match(csv, /"'\+1-555-0100"/);
});

test("bulk prospect export shares the full workspace query contract", async () => {
  const [dashboard, route, exportLib] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/prospect-export.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Export CSV/);
  assert.match(dashboard, /Select all.*across pages/);
  assert.match(dashboard, /setSelectionMode\("all_matching"\)/);
  assert.match(dashboard, /Choose prospects and fields/);
  assert.match(dashboard, /Fields to include/);
  assert.match(dashboard, /runProspectExport/);
  assert.match(dashboard, /fields: exportFields/);
  assert.match(dashboard, /excludedIds/);
  assert.match(dashboard, /search=\{deferredSearch\}/);
  // Exports go through exactly one path: the keyset endpoint that streams bounded
  // pages to disk. The old single-shot route buffered every matching row in memory
  // before writing a byte, so it must not come back.
  assert.match(route, /async function runProspectWorkspace/);
  assert.doesNotMatch(route, /exportProspects|prospectsCsv|X-Exported-Rows|export === "csv"/);
  // POST on this route is the LISTING carried in a body, not an export: a pasted
  // filter list can exceed Node's 16KB request line and be rejected with 431
  // before any handler runs. The export ban is the assertion above, which checks
  // for the export machinery itself rather than for a verb.
  assert.match(route, /respondToProspectQuery/);
  assert.doesNotMatch(route, /export async function PUT|export async function PATCH/);
  const exportRoute = await readFile(new URL("../app/api/prospects/export/route.ts", import.meta.url), "utf8");
  assert.match(exportRoute, /p_after_created_at/);
  assert.match(exportRoute, /nextCursor/);
  assert.match(exportRoute, /availableExportFieldIds/);
  assert.match(exportRoute, /from\("prospect_fields"\)/);
  assert.match(dashboard, /selectionMode === "ids"|selectionMode === "all_matching"/);
  // Shared export column contract lives in the reusable module.
  assert.match(exportLib, /row\.all_data/);
  assert.match(exportLib, /buildCustomFieldDefinitions/);
  assert.match(exportLib, /customFieldValue/);
  assert.match(exportLib, /"Email Provider Type"/);
  assert.match(exportLib, /"List Names"/);
  assert.match(exportLib, /"Client Names"/);
});

test("large exports stream keyset pages to disk in one file or split parts", async () => {
  const [endpoint, runner, dashboard, migration] = await Promise.all([
    readFile(new URL("../app/api/prospects/export/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/export-runner.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260902000020_people_workspace_uses_complete_sql.sql", import.meta.url), "utf8"),
  ]);

  // Keyset export endpoint: bounded page + cursor, safe under the 60s Hobby cap.
  // One function for scoped and unscoped exports alike; release-1a-correctness
  // records why v1 must not come back.
  assert.match(endpoint, /search_prospect_export_v4/);
  assert.doesNotMatch(endpoint, /search_prospect_export_v1/);
  assert.match(endpoint, /maxPageSize/);
  assert.match(endpoint, /nextCursor/);
  assert.match(endpoint, /excludedIds/);
  assert.match(endpoint, /buildExportColumns/);

  // SQL traverses (created_at, id) by cursor instead of a deep OFFSET.
  assert.match(migration, /FUNCTION public\.search_prospect_export_v4/);
  assert.match(migration, /p_after_created_at/);
  assert.match(migration, /order by matched\.created_at desc, matched\.id desc/);

  // Client runner streams to disk (File System Access) with single vs parts output.
  assert.match(runner, /showSaveFilePicker/);
  assert.match(runner, /showDirectoryPicker/);
  assert.match(runner, /streamMatchingPages/);
  assert.match(runner, /rowsPerFile/);
  assert.match(runner, /function fileSystemAccessSupported/);

  // Dialog exposes the single-file vs split-into-parts choice.
  assert.match(dashboard, /exportFormat/);
  assert.match(dashboard, /Split into parts/);
  assert.match(dashboard, /One CSV file/);
  assert.match(dashboard, /cancelExport/);
});
