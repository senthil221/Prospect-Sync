import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships full-field preservation, filters, and configurable columns", async () => {
  const [dashboard, prospectsRoute, startRoute, chunkRoute, migration, multiValueMigration] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/chunk/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260807020000_data_workspace.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260807030000_multi_value_filters.sql", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Field coverage/);
  assert.match(dashboard, /Choose columns/);
  assert.match(dashboard, /Use multiple values in each rule/);
  assert.match(dashboard, /MultiValueSelect/);
  assert.match(dashboard, /matches any value/);
  assert.match(dashboard, /master-scroll-top/);
  assert.match(dashboard, /syncHorizontalScroll/);
  assert.match(dashboard, /deriveListName\(next\.name\)/);
  assert.match(dashboard, /All .* fields will be preserved/);
  assert.match(dashboard, /__name.*__company.*__email.*__title/s);
  assert.match(prospectsRoute, /search_prospect_workspace/);
  assert.match(prospectsRoute, /contains.*equals.*empty.*not_empty/s);
  assert.match(startRoute, /field_headers/);
  assert.match(chunkRoute, /sourceRowNumber/);
  assert.match(chunkRoute, /import_prospect_batch_v2/);
  assert.match(migration, /create table if not exists public\.list_rows/);
  assert.match(migration, /unique\(import_id, source_row_number\)/);
  assert.match(migration, /create table if not exists public\.prospect_fields/);
  assert.match(multiValueMigration, /jsonb_array_elements_text/);
  assert.match(multiValueMigration, /filter_item->'values'/);
});
