import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseFilters } from "../lib/prospect-filters.ts";
import { filterChipValue } from "../lib/dashboard-helpers.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-06: ICP Unverified listed 492 companies the ICP check had already
// judged NON_FIT (214 with no domain for the blocklist to hold).
test("ICP Unverified means not verified and not NON_FIT, in all four filter paths", async () => {
  const migration = await read("../supabase/migrations/20261006090000_icp_unverified_excludes_non_fit.sql");
  for (const fn of ["prospect_filter_sql_v1", "prospect_index_matches_v1", "company_filter_sql_v3", "company_matches_filters_v1"]) {
    assert.ok(migration.includes(`pg_get_functiondef('public.${fn}(`), fn);
  }
  assert.ok(migration.includes("public.company_icp_check_matches_v1(pi.company_id, %1$L, 'NON_FIT')"));
  assert.ok(migration.includes("public.company_icp_check_matches_v1(c.id, %1$L, 'NON_FIT')"));
  assert.ok(migration.includes("not (%1$L = any (pi.icp_verified_client_ids))"));
  assert.ok(migration.includes("public.client_company_icp_validations iuv where iuv.client_id = %1$L and iuv.company_id = c.id"));
  assert.match(migration, /NON_FIT leaked/);
  assert.match(migration, /ICP Unverified proof passed/);
});

test("both ICP Unverified switches write the new filter, and old links still read as Unverified", async () => {
  assert.deepEqual(parseFilters(JSON.stringify([{ field: "__icp_unverified", operator: "equals", values: ["client-a"] }])),
    [{ field: "__icp_unverified", operator: "equals", values: ["client-a"] }]);
  assert.equal(filterChipValue("__icp_unverified", "client-a"), "Unverified, not NON_FIT");
  for (const [path, verifiedField] of [["../app/components/CompaniesWorkspace.tsx", "__company_icp_verified"], ["../app/components/ProspectTable.tsx", "__icp_verified"]]) {
    const source = await read(path);
    assert.ok(source.includes('const unverifiedField = status === "no_domain" ? "__icp_no_domain_unverified" : "__icp_unverified";'), path);
    assert.ok(source.includes('id: unverifiedField,\n      field: unverifiedField,\n      operator: "equals",'), path);
    assert.ok(source.includes('onClick={() => setIcpStatus("no_domain")}>No domain unverified</button>'), path);
    assert.ok(source.includes(`filter.field !== "${verifiedField}" && filter.field !== "__icp_unverified" && filter.field !== "__icp_no_domain_unverified"`), path);
    assert.ok(source.includes('icpFilter.field === "__icp_no_domain_unverified" ? "no_domain" : icpFilter.field === "__icp_unverified" || icpFilter.operator !== "contains" ? "unverified" : "verified"'), path);
  }
});

// 2026-10-06: NON_FIT companies with a domain go to the blocklist through the
// ICP check applier; those without one get their own tab.
test("NON_FIT companies with a domain are queued for the blocklist, without one get No domain unverified", async () => {
  const migration = await read("../supabase/migrations/20261006100000_icp_non_fit_blocklist_and_no_domain_view.sql");
  assert.match(migration, /set apply_pending = true,\n\s+applied = case when s\.applied = 'NON_FIT' then null else s\.applied end/);
  assert.ok(migration.includes("and not (s.applied = 'NON_FIT' and s.applied_blocked)"), "an entry removed by hand stays removed");
  assert.ok(migration.includes("and not public.is_free_email_domain_v1(c.normalized_domain)"));
  assert.ok(migration.includes("not exists (select 1 from public.client_company_icp_validations iv"));
  for (const fn of ["prospect_filter_sql_v1", "prospect_index_matches_v1", "company_filter_sql_v3", "company_matches_filters_v1"]) {
    assert.ok(migration.includes(`pg_get_functiondef('public.${fn}(`), fn);
  }
  assert.ok(migration.includes("coalesce(c.normalized_domain, '') = '' and not exists (select 1 from public.client_company_icp_validations ndv"));
  assert.ok(migration.includes("public.company_icp_check_matches_v1(pi.company_id, %1$L, 'NON_FIT')"));
  assert.match(migration, /No domain unverified proof passed/);
  assert.equal(filterChipValue("__icp_no_domain_unverified", "client-a"), "No domain, NON_FIT");
  assert.deepEqual(parseFilters(JSON.stringify([{ field: "__icp_no_domain_unverified", operator: "equals", values: ["client-a"] }])),
    [{ field: "__icp_no_domain_unverified", operator: "equals", values: ["client-a"] }]);
});
