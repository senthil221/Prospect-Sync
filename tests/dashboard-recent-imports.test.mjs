import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("dashboard recent imports combine completed people and company files", async () => {
  const [migration, route, overview] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260828193210_dashboard_recent_company_imports.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/dashboard/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/components/OverviewWorkspace.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /from public\.imports i[\s\S]+union all[\s\S]+from public\.company_imports ci/);
  assert.match(migration, /where i\.status = 'completed'/);
  assert.match(migration, /where ci\.status = 'completed'/);
  assert.match(migration, /order by created_at desc[\s\S]+limit 6/);
  assert.match(route, /from\("company_imports"\)/);
  assert.match(route, /\.eq\("status", "completed"\)/);
  assert.match(route, /\.sort\(\(left, right\) => Date\.parse\(right\.created_at\) - Date\.parse\(left\.created_at\)\)/);
  assert.match(overview, /People and company files imported recently/);
  assert.match(overview, /item\.kind === "companies"/);
  assert.match(overview, /item\.added_count/);
  assert.match(overview, /item\.updated_count/);
  assert.match(overview, /item\.skipped_count/);
  assert.match(overview, /item\.kind === "prospects" \? <button/);
});
