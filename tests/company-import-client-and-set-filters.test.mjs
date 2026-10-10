import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-10: a 1,500-domain list timed the Companies list out.
test("saved value lists compile to a set-first IN in both compilers", async () => {
  const sql = await read("../supabase/migrations/20261010130000_value_set_filters_resolve_the_set_first.sql");
  assert.ok(sql.includes("'lower(%2$s) in (select fsv.normalized_value from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %1$L::uuid)'"));
  assert.match(sql, /company_filter_sql_v3\(text,jsonb,boolean\).*then 1 else 2 end/s);
  assert.match(sql, /Filter set proof passed/);
});

// 2026-10-10: a company import can go to a client, tagged with its ICP.
test("a company import keeps its client and ICP tag and applies them page by page", async () => {
  const sql = await read("../supabase/migrations/20261010140000_company_import_client_and_icp_tag.sql");
  assert.match(sql, /add column if not exists client_tag_id text references public\.prospect_tags\(id\) on delete set null/);
  assert.match(sql, /public\.push_companies_to_client_v2\(v_import\.client_id, v_ids/);
  assert.match(sql, /insert into public\.company_tag_links \(company_id, tag_id\)/);
  assert.match(sql, /update public\.company_imports set client_assign_after = v_ids\[cardinality\(v_ids\)\]/);
  assert.ok(sql.includes("revoke execute on function public.apply_company_import_to_client_v1(text, integer, text) from public, anon, authenticated;"));
  const start = await read("../app/api/company-imports/start/route.ts");
  assert.match(start, /\.eq\("client_id", clientId\)\.eq\("tag_id", clientTagId\)/);
  assert.match(start, /client_tag_id: clientTagId,/);
  const assign = await read("../app/api/company-imports/assign/route.ts");
  assert.match(assign, /await authorizeApi\(\)/);
  assert.match(assign, /rpc\("apply_company_import_to_client_v1"/);
  const panel = await read("../app/components/ImportsPanel.tsx");
  assert.match(panel, /<label htmlFor="company-import-client">Add to client \(optional\)<\/label>/);
  assert.match(panel, /<label htmlFor="company-import-icp">ICP tag \(optional\)<\/label>/);
  assert.match(panel, /"\/api\/company-imports\/assign"/);
  assert.match(panel, /clientId: importClientId \|\| undefined, clientTagId: importClientId && importTagId \? importTagId : undefined/);
});
