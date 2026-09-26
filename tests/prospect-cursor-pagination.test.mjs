import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { prospectApiPath } from "../lib/dashboard-api.ts";
import {
  decodeProspectCursor,
  encodeProspectCursor,
  isProspectCursorEligible,
  prospectCursorQueryHash,
} from "../lib/prospect-pagination.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("People cursors are opaque, query-bound, and reject malformed boundaries", () => {
  const identity = {
    search: "director",
    filters: [{ field: "__list_ids", operator: "contains", values: ["list-1"] }],
    sort: "created_at",
    direction: "desc",
    clientId: "client-1",
  };
  const hash = prospectCursorQueryHash(identity);
  const encoded = encodeProspectCursor({ id: "prospect-b", created_at: "2026-09-26T08:00:00.000Z" }, hash);
  assert.ok(encoded);
  assert.deepEqual(decodeProspectCursor(encoded, hash), {
    version: 1,
    queryHash: hash,
    createdAt: "2026-09-26T08:00:00.000Z",
    id: "prospect-b",
  });
  assert.equal(decodeProspectCursor(encoded, prospectCursorQueryHash({ ...identity, search: "vp" })), null);
  assert.equal(decodeProspectCursor("not-json", hash), null);
  assert.equal(encodeProspectCursor({ id: "prospect-b", created_at: "not-a-date" }, hash), null);
});

test("cursor eligibility is additive and keeps unsupported/deep-link cases on OFFSET", () => {
  const base = {
    featureEnabled: true,
    requested: true,
    page: 1,
    rawCursor: "",
    sort: "created_at",
    direction: "desc",
    companyScoped: false,
    filters: [{ field: "__list_ids" }],
  };
  assert.equal(isProspectCursorEligible(base), true, "list filters remain eligible");
  assert.equal(isProspectCursorEligible({ ...base, page: 2 }), false, "old numeric deep links have no cursor");
  assert.equal(isProspectCursorEligible({ ...base, page: 2, rawCursor: "opaque" }), true);
  assert.equal(isProspectCursorEligible({ ...base, featureEnabled: false }), false);
  assert.equal(isProspectCursorEligible({ ...base, sort: "name" }), false);
  assert.equal(isProspectCursorEligible({ ...base, direction: "asc" }), false);
  assert.equal(isProspectCursorEligible({ ...base, companyScoped: true }), false);
  assert.equal(isProspectCursorEligible({ ...base, filters: [{ field: "__max_people_per_company" }] }), false);
  for (const field of [
    "__company_industry", "__company_keywords", "__company_description",
    "__company_technologies", "__company_founded_year", "__company_total_funding",
    "__incomplete_company_profile",
  ]) {
    assert.equal(isProspectCursorEligible({ ...base, filters: [{ field }] }), false, `${field} must retain v12 count/version semantics`);
  }
});

test("People API transport carries cursor mode in GET and preserves page numbers", () => {
  const url = new URL(prospectApiPath({ page: 3, pagination: "cursor", cursor: "opaque" }), "https://example.test");
  assert.equal(url.searchParams.get("page"), "3");
  assert.equal(url.searchParams.get("pagination"), "cursor");
  assert.equal(url.searchParams.get("cursor"), "opaque");
  assert.equal(new URL(prospectApiPath({ page: 3 }), "https://example.test").searchParams.has("cursor"), false);
});

test("cursor SQL preserves the mixed created_at DESC/id ASC boundary and service-role contract", async () => {
  const sql = await read("../supabase/migrations/20260926083856_prospect_people_cursor_v1.sql");
  const boundaryLines = sql.split(/\r?\n/u).map((line) => line.trim()).filter((line) => line && !line.startsWith("--"));
  assert.notEqual(boundaryLines[0]?.toLowerCase(), "begin;", "the deploy runner owns the transaction");
  assert.notEqual(boundaryLines.at(-1)?.toLowerCase(), "commit;", "the deploy runner owns the transaction");
  assert.match(sql, /order by pi\.created_at desc, pi\.id/);
  assert.match(sql, /pi\.created_at < %3\$L::timestamptz[\s\S]*pi\.created_at = %3\$L::timestamptz and pi\.id > %4\$L/);
  assert.match(sql, /client_rows\.sort_key < %3\$L::timestamptz[\s\S]*client_rows\.id > %4\$L/);
  assert.match(sql, /revoke execute on function public\.search_prospect_workspace_cursor_v1[\s\S]*from public, anon, authenticated/);
  assert.match(sql, /grant execute on function public\.search_prospect_workspace_cursor_v1[\s\S]*to service_role/);
  assert.match(sql, /set search_path = pg_catalog, public/);
  assert.match(sql, /prospect_filters_need_company_lookup_v1\(v_filters\)/);
  assert.match(sql, /cursor v1 accepted company-dependent filter/);
  assert.match(sql, /global People cursor page differs from OFFSET page/);
  assert.match(sql, /client People cursor page differs from OFFSET page/);
  assert.match(sql, /list-filtered People cursor page differs from OFFSET page/);
});

test("disposable PostgreSQL replay is release-gating and non-skipping", async () => {
  const [workflow, runner, seed, checks, compatibility, historyVolumeCleanup, roles] = await Promise.all([
    read("../.github/workflows/ci.yml"),
    read("../scripts/test-prospect-cursor-migration.mjs"),
    read("../scripts/prospect-cursor-history-fixture.sql"),
    read("../scripts/check-prospect-cursor-migration.sql"),
    read("../scripts/prospect-cursor-history-compat.sql"),
    read("../scripts/prospect-cursor-history-volume-cleanup.sql"),
    read("../scripts/prospect-cursor-ci-roles.sql"),
  ]);
  assert.match(workflow, /cursor-migration-contract:[\s\S]*image: postgres:15/);
  assert.doesNotMatch(workflow, /cursor-migration-contract:[\s\S]*if: github\.event_name == ['"]pull_request['"]/);
  assert.match(workflow, /CURSOR_MIGRATION_TEST_ALLOW: "1"/);
  assert.match(runner, /database !== 'cursor_migration_test'/);
  assert.match(runner, /disposable cursor migration database is not empty/);
  assert.match(runner, /if \(file === seedBefore\)[\s\S]*historical cursor data fixture/);
  assert.doesNotMatch(runner, /migrationFiles\.at\(-1\) !== candidate/, "later migrations must remain replayable");
  assert.match(runner, /if \(file === candidate\) candidateApplied = true/);
  assert.match(runner, /::error title=Cursor migration replay::/);
  assert.match(runner, /find\(\(line\) => \/\\bERROR:/);
  assert.match(runner, /replaceAll\('disposable-ci-only', '\[redacted\]'\)/);
  assert.match(runner, /reviewedHistoryHashes = new Map/);
  assert.match(runner, /createHash\('sha256'\)/);
  assert.equal((runner.match(/Applying one reviewed CI-only compatibility exception/g) ?? []).length, 1);
  assert.doesNotMatch(runner, /retry/i, "the historical exception must not become a generic retry path");
  assert.match(runner, /compatibilityExceptionCount !== 1/);
  assert.match(runner, /insert into supabase_migrations\.schema_migrations/);
  assert.match(runner, /synthetic migration ledger does not contain every replayed migration/);
  assert.match(runner, /Proving candidate RPC and ledger rollback before applying/);
  assert.match(runner, /forced cursor candidate rollback/);
  assert.match(runner, /rollback;`/);
  assert.match(runner, /candidate rollback postcondition/);
  assert.match(runner, /cursor RPC exists/);
  assert.match(runner, /cursor migration ledger entry exists/);
  assert.match(compatibility, /v_phase = 'pre'/);
  assert.match(compatibility, /array\['p_import_id', 'p_rows', 'processed', 'added', 'updated', 'skipped'\]/);
  assert.match(compatibility, /drop function public\.import_company_batch_v2\(text, jsonb\) restrict/);
  assert.doesNotMatch(compatibility, /cascade/i);
  assert.match(compatibility, /v_phase = 'post'/);
  assert.match(compatibility, /array\['p_import_id', 'p_rows', 'p_row_offset', 'processed', 'added', 'updated', 'skipped'\]/);
  assert.match(compatibility, /has_function_privilege[\s\S]*'anon'/);
  assert.match(compatibility, /has_function_privilege[\s\S]*'authenticated'/);
  assert.match(compatibility, /has_function_privilege[\s\S]*'service_role'/);
  assert.match(seed, /generate_series\(1, 130\)/);
  assert.match(seed, /generate_series\(1, 21\)/);
  assert.match(seed, /generate_series\(1, 19849\)/);
  assert.match(seed, /19849::bigint, 20000::bigint/);
  assert.match(runner, /historyVolumeAssertion = '20260902000280_esp_equals_matches_either_column\.sql'/);
  assert.match(runner, /historical 20,000-row assertion fixture cleanup/);
  assert.match(historyVolumeCleanup, /delete from public\.prospects/);
  assert.match(historyVolumeCleanup, /0::bigint, 151::bigint, 151::bigint/);
  for (const worker of [
    "prospect_import_worker",
    "prospect_ops_worker",
    "prospect_integration_worker",
  ]) {
    assert.match(roles, new RegExp(`create role ${worker} login inherit`));
    assert.doesNotMatch(roles, new RegExp(`create role ${worker} login noinherit`));
  }
  assert.match(seed, /151::bigint, 151::bigint, 130::bigint, 21::bigint/);
  assert.match(seed, /110::bigint, 132::bigint, 2::bigint/);
  assert.match(checks, /assert_cursor_case\('global'/);
  assert.match(checks, /assert_cursor_case\('client A'/);
  assert.match(checks, /'person filter'/);
  assert.match(checks, /'list A filter'/);
  assert.match(checks, /v_all_ids && v_page_ids/);
  assert.match(checks, /did not traverse a final partial page/);
  assert.match(checks, /v_cursor\.total_count <> 151/);
  assert.match(checks, /PUBLIC execute privilege differs from workspace v12 or remains granted/);
});

test("route and both People controllers retain cursor fallback and back-navigation edges", async () => {
  const [route, master, clients, api] = await Promise.all([
    read("../app/api/prospects/route.ts"),
    read("../app/components/ProspectsWorkspace.tsx"),
    read("../app/components/ClientsPanel.tsx"),
    read("../lib/dashboard-api.ts"),
  ]);
  assert.match(route, /PROSPECT_CURSOR_PAGINATION === "1"/);
  assert.match(route, /search_prospect_workspace_cursor_v1/);
  assert.match(route, /runProspectWorkspace\(supabase, workspaceQuery\)/, "v13 OFFSET fallback remains wired");
  assert.match(route, /pagination: cursorEligible \? \{ mode: "cursor", nextCursor \} : \{ mode: "offset", nextCursor: null \}/);
  for (const controller of [master, clients]) {
    assert.match(controller, /prospectCursorShapeSupported/);
    assert.match(controller, /pageCursors = useRef\(new Map<number, string>\(\[\[1, ""\]\]\)\)/);
    assert.match(controller, /pageCursors\.current\.get\(page\)/);
    assert.match(controller, /pageCursors\.current\.set\(page \+ 1, data\.pagination\.nextCursor\)/);
  }
  assert.match(master, /cursorQueryKey[\s\S]*statsProspects/);
  assert.match(clients, /cursorQueryKey[\s\S]*client\.prospect_count/);
  assert.match(api, /query\.pagination === "cursor"/);
  assert.match(api, /query\.cursor \? \{ cursor: query\.cursor \}/);
});
