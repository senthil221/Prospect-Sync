import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// 2026-10-09: the Overview timed out and the Clients list took 12s because both
// recomputed their caches on the page request against a cold database.
test("Overview and Clients serve their caches; the operations worker refreshes them", async () => {
  const sql = await readFile(new URL("../supabase/migrations/20261009090000_page_loads_never_recount.sql", import.meta.url), "utf8");
  const overview = sql.slice(sql.indexOf("FUNCTION public.dashboard_workspace()"), sql.indexOf("FUNCTION public.client_summaries_v1"));
  assert.doesNotMatch(overview, /count\(\*\) from public\.(prospect_index|companies)/);
  assert.match(overview, /where s\.key = 'workspaceCounts';/);
  assert.match(overview, /reltuples/);
  assert.match(sql, /elsif p_client_id is null and v_cache_found\s+and v_cache\.version = v_version/);
  const refresher = sql.slice(sql.indexOf("FUNCTION prospect_operations.refresh_dashboard_snapshots_v1()"));
  assert.match(refresher, /insert into public\.client_summary_cache/);
  assert.match(refresher, /array\['workspaceCounts', 'dataQuality', 'indexDrift', 'titleTaxonomy'\]/);
  assert.match(refresher, /when 'workspaceCounts' then jsonb_build_object/);
  for (const fn of ["public.dashboard_workspace()", "public.client_summaries_v1(text)", "prospect_operations.refresh_dashboard_snapshots_v1()"]) {
    assert.ok(sql.includes(`revoke execute on function ${fn} from public, anon, authenticated;`), fn);
  }
});
