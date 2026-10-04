import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  clientCompanyScopeField,
  filtersHaveCallerIntent,
  withClientCompanyScope,
} from "../lib/client-workspace-completeness.ts";
import { normalizeResultSetQuestion, resultSetContentHash } from "../lib/result-sets.ts";
import { companyScopeHasIntent, normalizeCompanyScope } from "../lib/workspace-scopes.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const scopeFilter = (client = "client-a", operator = "equals", values = [client]) => ({
  id: "caller-supplied", field: clientCompanyScopeField, operator, values,
});

test("client company scope is canonical, intersectable and idempotent", () => {
  const ordinary = [{ id: "shared-with-b", field: "__company_client_ids", operator: "contains", values: ["client-b"] }];
  const normalized = withClientCompanyScope([...ordinary, scopeFilter("client-b")], "client-a");
  assert.deepEqual(normalized, [
    ordinary[0],
    { id: "client-profile:complete", field: "__incomplete_company_profile", operator: "equals", values: ["false"] },
    { id: "client-seg:policy", field: "__client_seg_policy", operator: "equals", values: ["client-a"] },
    { id: "client-company:scope", field: clientCompanyScopeField, operator: "equals", values: ["client-a"] },
  ]);
  assert.equal(withClientCompanyScope(normalized, "client-a"), normalized);
  assert.throws(() => withClientCompanyScope([scopeFilter("x", "contains")], "client-a"), /Invalid server-owned/);
  assert.throws(() => withClientCompanyScope([scopeFilter("x"), scopeFilter("x")], "client-a"), /Invalid server-owned/);
  assert.throws(() => withClientCompanyScope([scopeFilter("", "equals", [""])], "client-a"), /Invalid server-owned/);
});

test("Master company questions remain unchanged and reject internal client claims", () => {
  const ordinary = [{ field: "__company_coverage", operator: "equals", values: ["with"] }];
  assert.equal(withClientCompanyScope(ordinary, ""), ordinary);
  const legacySeg = [{ field: "__client_seg_policy", operator: "equals", values: ["client-a"] }];
  assert.equal(withClientCompanyScope(legacySeg, ""), legacySeg,
    "a pre-release tab may still send the established SEG predicate without clientScope");
  const legacyScope = { search: "software", filters: legacySeg, limit: 250000 };
  assert.equal(normalizeCompanyScope(legacyScope, null), legacyScope);
  assert.throws(() => withClientCompanyScope([scopeFilter()], ""), /server-managed/);
  assert.throws(() => normalizeCompanyScope({ search: "software", filters: [scopeFilter()], limit: 250000 }, null), /server-managed/);
});

test("server fields cannot manufacture caller intent, while Incomplete Info can", () => {
  const internal = [
    scopeFilter(),
    { field: "__client_seg_policy", operator: "equals", values: ["client-a"] },
  ];
  assert.equal(filtersHaveCallerIntent(internal), false);
  assert.equal(companyScopeHasIntent({ search: "", filters: internal, limit: 250000 }), false);
  assert.equal(normalizeCompanyScope({ search: "", filters: internal, limit: 250000 }, "client-a"), null);

  const incomplete = [{ field: "__incomplete_company_profile", operator: "equals", values: ["true"] }];
  assert.equal(filtersHaveCallerIntent(incomplete), true);
  const normalized = normalizeCompanyScope({ search: "", filters: incomplete, limit: 250000 }, "client-a");
  assert.ok(normalized);
  assert.deepEqual(normalized.filters, [
    incomplete[0],
    { id: "client-seg:policy", field: "__client_seg_policy", operator: "equals", values: ["client-a"] },
    { id: "client-company:scope", field: clientCompanyScopeField, operator: "equals", values: ["client-a"] },
  ]);
});

test("nested client scope has one stable result-set identity", () => {
  const requested = {
    entityType: "prospect", clientScope: "client-a", search: "",
    filters: [{ field: "__title", operator: "contains", values: ["founder"] }],
    companyScope: {
      search: "", limit: 250000,
      filters: [
        { field: "__company_coverage", operator: "equals", values: ["without"] },
        scopeFilter("client-b"),
      ],
    },
  };
  const normalized = normalizeResultSetQuestion(requested);
  assert.equal(normalized.companyScope.filters.at(-1).field, clientCompanyScopeField);
  assert.deepEqual(normalized.companyScope.filters.at(-1).values, ["client-a"]);
  assert.equal(normalizeResultSetQuestion(normalized), normalized);
  assert.equal(
    resultSetContentHash(normalized),
    resultSetContentHash(normalizeResultSetQuestion(normalized)),
  );
});

test("all server entry points normalize before authorization, hashing or execution", async () => {
  const [resultSets, exportsRoute, people, peopleExport, companies, runner, verifications] = await Promise.all([
    read("../app/api/result-sets/route.ts"),
    read("../app/api/exports/route.ts"),
    read("../app/api/prospects/route.ts"),
    read("../app/api/prospects/export/route.ts"),
    read("../app/api/companies/route.ts"),
    read("../lib/export-runner.ts"),
    read("../app/api/verifications/route.ts"),
  ]);
  assert.match(resultSets, /filtersHaveCallerIntent\(filters\)/);
  assert.ok(resultSets.indexOf("normalizeCompanyScope(companyScope, clientScope)") < resultSets.indexOf("normalizeResultSetQuestion({"));
  assert.ok(resultSets.indexOf("normalizeResultSetQuestion({") < resultSets.indexOf("authorizeFilterSets(supabase, filters"));
  assert.match(exportsRoute, /\(\{ filters, companyScope: scopePayload \} = normalizeResultSetQuestion/);
  assert.match(people, /companyScope = normalizeCompanyScope\(companyScope, clientId\)/);
  assert.match(peopleExport, /companyScope = normalizeCompanyScope\(companyScope, clientId\)/);
  assert.match(companies, /filters = withClientCompanyScope\(filters, clientId\)/);
  assert.match(runner, /clientScope: options\.clientId \?\? ""/);
  assert.match(runner, /clientId: options\.clientId \?\? ""/);
  assert.match(verifications, /companyScope = normalizeCompanyScope\(companyScope, null\)/);
});

test("the migration keeps runtime work bounded and CI proves all execution paths", async () => {
  const [migration, runner, fixture] = await Promise.all([
    read("../supabase/migrations/20261004095510_align_client_company_scope.sql"),
    read("../scripts/test-production-hardening-migrations.mjs"),
    read("../supabase/tests/client_company_scope_parity.sql"),
  ]);
  assert.match(migration, /client_company_scope_value_v1/);
  assert.match(migration, /jsonb_typeof\(v_item->'values'->0\) is distinct from 'string'/);
  assert.doesNotMatch(migration.slice(migration.indexOf("do $proof$")), /from public\.companies c where %s/);
  assert.match(runner, /client_company_scope_parity\.sql/);
  for (const contract of [
    "company_filter_sql_v3", "company_matches_filters_v1", "company_prefilter_sql",
    "client_company_workspace_v2", "search_company_export_v2", "company_scope_ids_v2",
    "resolve_company_action_selection_v1",
  ]) assert.match(fixture, new RegExp(contract));
  assert.match(fixture, /scope-global-not-a/);
  assert.match(fixture, /Master coverage semantics changed/);
});

test("the Company DB removes the redundant verdict selector but preserves visible legacy filters", async () => {
  const source = await read("../app/components/CompaniesWorkspace.tsx");
  assert.doesNotMatch(source, />Any ICP check</);
  assert.doesNotMatch(source, />FIT</);
  assert.doesNotMatch(source, />NON_FIT</);
  assert.match(source, />ICP Verified</);
  assert.match(source, />ICP Unverified</);
  assert.match(source, /legacyIcpCheckFilters\.map/);
  assert.match(source, /Exclude saved ICP results/);
  assert.match(source, /\.join\(", "\)/);
  assert.match(source, /onPageChange\(1\); clearSelection\(\);/);
});
