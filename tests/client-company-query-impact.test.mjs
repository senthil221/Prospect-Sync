import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { boundedDatabaseAbortResponse } from "../lib/api-errors.ts";
import {
  canAdvanceClientCompanyPage,
  clientCompanyHasMore,
  clientCompanyPageRequest,
} from "../lib/client-company-pagination.ts";
import { planExport } from "../lib/export-plan.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("client Company DB listing reads the maintained membership count", async () => {
  const sql = await read("../supabase/migrations/20261005063325_client_company_workspace_reads_stored_counts.sql");
  const definition = sql.match(/create or replace function public\.client_company_workspace_v2[\s\S]*?revoke execute on function public\.client_company_workspace_v2/i)?.[0] ?? "";
  assert.match(definition, /membership\.prospect_count/);
  assert.doesNotMatch(definition, /from public\.prospect_index/i);
  assert.doesNotMatch(definition, /join lateral\s*\(/i);
  assert.match(definition, /order by prospect_count desc, lower\(name\), id/);
  assert.match(definition, /count\(\*\) > 50000/);
  assert.match(sql, /recompute_client_company_counts_bulk\(v_ids\)/);
  assert.match(sql, /from public, anon, authenticated;/);
  assert.match(sql, /to service_role;/);
});

test("client company route combines disconnect cancellation, deadline and look-ahead paging", async () => {
  const route = await read("../app/api/companies/route.ts");
  assert.match(route, /const querySignal = signal \? AbortSignal\.any\(\[signal, deadline\]\) : deadline;/);
  assert.match(route, /const \{ canLookAhead, rpcLimit \} = clientCompanyPageRequest\(pageSize\)/);
  assert.match(route, /p_limit: rpcLimit/);
  assert.match(route, /\.abortSignal\(querySignal\)/);
  assert.match(route, /boundedDatabaseAbortResponse/);
  assert.match(route, /clientCompanyHasMore\(resultRows\.length, pageSize, canLookAhead\)/);
  assert.match(route, /resultRows\.slice\(0, pageSize\)/);
});

test("100-row client pages retain navigation without exceeding the RPC cap", () => {
  assert.deepEqual(clientCompanyPageRequest(50), { canLookAhead: true, rpcLimit: 51 });
  assert.deepEqual(clientCompanyPageRequest(100), { canLookAhead: false, rpcLimit: 100 });
  assert.equal(clientCompanyHasMore(51, 50, true), true);
  assert.equal(clientCompanyHasMore(50, 50, true), false);
  assert.equal(clientCompanyHasMore(100, 100, false), undefined);
  assert.equal(canAdvanceClientCompanyPage({ hasMore: undefined, totalCapped: true, rowCount: 100, pageSize: 100, page: 500, total: 50000 }), true);
  assert.equal(canAdvanceClientCompanyPage({ hasMore: undefined, totalCapped: true, rowCount: 51, pageSize: 100, page: 501, total: 50000 }), false);
  assert.equal(canAdvanceClientCompanyPage({ hasMore: undefined, totalCapped: false, rowCount: 100, pageSize: 100, page: 5, total: 500 }), false);
});

test("capped company totals keep complete-scope export on the unknown-size background path", () => {
  const plan = planExport({ rows: null, bytesPerRow: 64 });
  assert.equal(plan.mode, "background");
  assert.equal(plan.rows, null);
  assert.match(plan.reason, /number of matching rows is not known/i);
});

test("bounded database cancellation distinguishes caller, route deadline, and PostgreSQL timeout", async () => {
  const caller = new AbortController();
  const deadline = new AbortController();
  caller.abort();
  let response = boundedDatabaseAbortResponse({ callerSignal: caller.signal, deadlineSignal: deadline.signal, subject: "View", alternative: "Narrow it." });
  assert.ok(response);
  assert.equal(response.status, 499);
  assert.deepEqual(await response.json(), { error: "The request was cancelled." });

  const openCaller = new AbortController();
  deadline.abort();
  response = boundedDatabaseAbortResponse({ callerSignal: openCaller.signal, deadlineSignal: deadline.signal, subject: "View", alternative: "Narrow it." });
  assert.ok(response);
  assert.equal(response.status, 504);
  assert.equal((await response.json()).code, "statement_timeout");

  const openDeadline = new AbortController();
  response = boundedDatabaseAbortResponse({ callerSignal: openCaller.signal, deadlineSignal: openDeadline.signal, error: { code: "57014" }, subject: "View", alternative: "Narrow it." });
  assert.ok(response);
  assert.equal(response.status, 504);
  assert.equal(boundedDatabaseAbortResponse({ callerSignal: openCaller.signal, deadlineSignal: openDeadline.signal, error: { code: "XX000" }, subject: "View", alternative: "Narrow it." }), null);
});

test("client company UI preserves cap state and pages beyond its lower bound honestly", async () => {
  const [clients, companies] = await Promise.all([
    read("../app/components/ClientsPanel.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
  ]);
  assert.match(clients, /totalCapped: data\.totalCapped === true/);
  assert.match(clients, /totalCapped=\{summary\.totalCapped\}/);
  assert.match(clients, /hasMore=\{summary\.hasMore\}/);
  assert.match(companies, /const resultEnd = companies\.length \? resultStart \+ companies\.length - 1 : 0/);
  assert.match(companies, /const displayedTotal = totalCapped \? Math\.max\(total, resultEnd\) : total/);
  assert.match(companies, /const canGoNext = canAdvanceClientCompanyPage/);
  assert.match(companies, /disabled=\{!canGoNext\}/);
  assert.match(companies, /at least this many match/);
});

test("disposable PostgreSQL gate proves write authority, cap and complete export", async () => {
  const [runner, authority, cap] = await Promise.all([
    read("../scripts/test-production-hardening-migrations.mjs"),
    read("../supabase/tests/client_company_stored_count_authority.sql"),
    read("../supabase/tests/client_company_capped_pagination.sql"),
  ]);
  assert.match(runner, /client_company_stored_count_authority\.sql/);
  assert.match(runner, /client_company_capped_pagination\.sql/);
  for (const contract of [
    /import_prospect_batch_v5/,
    /push_prospects_to_client_v2/,
    /add_client_blocklist_batch_v2/,
    /remove_client_blocklist_v1/,
    /remove_prospects_from_client_v2/,
    /update public\.prospects set company_id/,
  ]) assert.match(authority, contract);
  assert.match(cap, /generate_series\(1, 50051\)/);
  assert.match(cap, /p_limit=100 boundary/i);
  assert.match(cap, /v_workspace\.total_count <> 50000 or not v_workspace\.total_capped/);
  assert.match(cap, /v_exported <> 50051/);
});
