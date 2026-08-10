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
  const [dashboard, route] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /↓ Export all/);
  assert.match(dashboard, /new URLSearchParams\(\{ export: "csv", sort, direction \}\)/);
  assert.match(dashboard, /params\.set\("filters"/);
  assert.match(dashboard, /params\.set\("clientId"/);
  assert.match(dashboard, /search=\{deferredSearch\}/);
  assert.match(route, /async function runProspectWorkspace/);
  assert.match(route, /search_prospect_workspace_v5/);
  assert.match(route, /p_limit: query\.limit/);
  assert.match(route, /p_offset: query\.offset/);
  assert.match(route, /async function exportProspects/);
  assert.match(route, /from\("prospect_fields"\)/);
  assert.match(route, /row\.all_data/);
  assert.match(route, /"X-Exported-Rows"/);
  assert.match(route, /"Email Provider Type"/);
  assert.match(route, /"List Names"/);
  assert.match(route, /"Client Names"/);
});
