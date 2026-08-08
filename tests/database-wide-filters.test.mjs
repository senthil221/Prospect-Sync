import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("filter pickers search values across the database instead of the current page", async () => {
  const [dashboard, route, migration, workspaceMigration] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/prospects/filter-values/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260808020000_database_wide_filter_values.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260808010000_client_scoped_workspaces.sql", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /api\/prospects\/filter-values/);
  assert.match(dashboard, /Searches every record, not only this page/);
  assert.match(dashboard, /clientId=\{client\.id\}/);
  assert.match(dashboard, /selectedRows\.values\(\)/);
  assert.match(dashboard, /selected across pages/);
  assert.match(route, /prospect_filter_values/);
  assert.match(route, /p_client_id: clientId/);
  assert.match(migration, /create or replace function public\.prospect_filter_values/);
  assert.match(migration, /cross join lateral unnest\(ps\.list_names\)/);
  assert.match(migration, /count\(distinct prospect_id\)/);
  assert.match(migration, /where p_client_id is null or p_client_id = any\(ps\.client_ids\)/);

  const filterPosition = workspaceMigration.indexOf("), filtered as materialized");
  const limitPosition = workspaceMigration.indexOf("limit greatest", filterPosition);
  assert.ok(filterPosition >= 0 && limitPosition > filterPosition, "prospect filters must run before pagination");
});
