import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { resultSetContentHash, ownerIdentity } from "../lib/result-sets.ts";

// Release 2 items 2 and 3, finally reachable: a question answered in the
// background, and a bulk action that runs over exactly the ids the user chose.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
// Several assertions below are about what the code does NOT do. Prose explaining
// why would match those patterns just as well as the code would, and has done
// three times before, so the comments come out first.
const codeOnly = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("--")).join("\n");

test("the frozen selection is applied from stored ids, never re-resolved", async () => {
  const migration = await read("../supabase/migrations/20260902000160_run_the_frozen_selection.sql");
  const code = codeOnly(migration);

  // The whole point: the four mutations are called with explicit ids and an
  // empty question. If a filter payload ever reached one of them the operation
  // could act on rows the user never saw.
  for (const rpc of [
    "push_prospects_to_client_v1",
    "set_icp_verified_v1",
    "set_client_date_contacted_v1",
    "remove_prospects_from_client_v2",
  ]) {
    assert.match(code, new RegExp(`public\\.${rpc}\\(`), `${rpc} should be applied by the worker`);
  }
  assert.equal(code.match(/p_search => ''/g)?.length, 4);
  assert.equal(code.match(/p_filters => '\[\]'::jsonb/g)?.length, 4);
  assert.equal(code.match(/p_prospect_ids => v_ids/g)?.length, 4);

  // Progress and mutation land together or not at all.
  assert.match(code, /v_marked := prospect_operations\.mark_applied_v1\(p_job_id, v_ids\);/);
});

test("the worker gets four verbs, and loses the two that could desynchronize it", async () => {
  const migration = await read("../supabase/migrations/20260902000160_run_the_frozen_selection.sql");
  const code = codeOnly(migration);

  for (const granted of ["claim_next_v1(text, integer)", "apply_batch_v1(uuid, integer, integer)", "fail_v1(uuid, text)", "expire_jobs_v1()"]) {
    assert.match(code, new RegExp(`grant execute on function prospect_operations\\.${granted.replace(/[()[\]]/g, "\\$&")} to prospect_operator;`));
  }
  // 20260902000140 handed these out for a worker that would mutate and record
  // progress as two calls. apply_batch_v1 does both in one transaction, so
  // holding them separately could only ever mark ids applied that were not.
  assert.match(code, /revoke execute on function prospect_operations\.next_batch_v1\(uuid, integer\) from prospect_operator;/);
  assert.match(code, /revoke execute on function prospect_operations\.mark_applied_v1\(uuid, text\[\]\) from prospect_operator;/);

  // The application's door is service_role's alone, and the migration proves it
  // in the transaction that opens it rather than trusting the grants above.
  assert.match(code, /must not be reachable by anon or authenticated/);
  assert.match(code, /prospect_operator must not read prospect_index/);
  assert.match(code, /prospect_operator must not read client_prospects/);
});

test("a result set's freshness is judged against the world, not against the tab", async () => {
  const migration = await read("../supabase/migrations/20260902000160_run_the_frozen_selection.sql");

  // Both wrappers take the version vector themselves. A browser-supplied one
  // could only ever make a stale set look fresh.
  assert.match(migration, /coalesce\(p_version_vector, public\.data_versions_v1\(array\[p_entity_type\]\)\)/);
  assert.match(migration, /v_vector := public\.data_versions_v1\(array\[v_entity\]\)/);

  const route = await read("../app/api/result-sets/route.ts");
  assert.match(route, /p_version_vector: null/);
});

test("all matching freezes; it does not fall through to a server-side resolve", async () => {
  const route = await read("../app/api/clients/[id]/prospects/route.ts");
  const code = codeOnly(route);

  assert.match(code, /const resultSetId = String\(payload\.resultSetId \?\? ""\)\.trim\(\);/);
  assert.match(code, /const frozen = await freezeFromResultSet\(supabase, operation\.jobId, actor, resultSetId\);/);
  // A freeze that fails must stop the request. Falling through would resolve
  // the filters at execution time - the exact widening this prevents.
  assert.match(code, /if \(frozen\.error\) return frozen\.error;/);
  assert.match(code, /\}, \{ status: 202 \}\);/);

  // Every action records what it answered. Without this the job stays open and
  // a retry re-runs the mutation instead of being answered from the first run.
  assert.doesNotMatch(code, /return Response\.json\(\{ result: data \}\);/);
  assert.equal(code.match(/return finish\(data\);/g)?.length, 4);

  // The worker has nobody to ask, so the parameters are validated and stored
  // before the job exists rather than inside the branch that runs it.
  assert.match(code, /const jobPayload: Record<string, unknown> = \{/);
  assert.match(code, /\.\.\.\(action === "set_date_contacted" \? \{ dateContacted: dateContacted \?\? null \} : \{\}\)/);
});

test("polling opts out of the response cache and is bounded", async () => {
  const helper = await read("../lib/background-operation.ts");
  const code = codeOnly(helper);

  // api() caches GETs for five minutes; a status poll would return the first
  // answer forever without this.
  assert.equal(code.match(/cache: "no-store"/g)?.length, 2);
  assert.match(code, /delay = Math\.min\(maxDelayMs, Math\.round\(delay \* 1\.5\)\);/);
  assert.match(code, /const defaultDeadlineMs = 15 \* 60_000;/);
  // A replayed operation has no job to watch: that is the idempotency working.
  assert.match(code, /if \(started\.replayed\)/);
  // A failed job says how far it got. "Nothing happened" would be untrue.
  assert.match(code, /stopped after \$\{settled\.appliedItems\} of \$\{settled\.totalItems\}/);
});

test("the owner of a result set and the actor of an operation are one identity", () => {
  // freeze_operation_from_result_set_v1 looks the set up by the job's actor, so
  // if these two ever diverged every background action would answer "not yours".
  assert.equal(ownerIdentity({ email: "a@b.test", id: "uuid-1" }), "a@b.test");
  assert.equal(ownerIdentity({ email: "", id: "uuid-1" }), "uuid-1");
  assert.equal(ownerIdentity({ email: null, id: null }), "");
  assert.equal(ownerIdentity(null), "");
});

test("a result set is identified by the question, not by who asked it", () => {
  const question = { entityType: "prospect", clientScope: "", search: "cto", filters: [{ field: "__title", operator: "contains", values: ["chief"] }] };
  assert.equal(resultSetContentHash(question), resultSetContentHash({ ...question, search: "  cto  " }));
  assert.notEqual(resultSetContentHash(question), resultSetContentHash({ ...question, clientScope: "client-1" }));
  assert.notEqual(resultSetContentHash(question), resultSetContentHash({ ...question, filters: [] }));
});

test("a capped count can be turned into a real one, and is dropped when the question changes", async () => {
  const table = await read("../app/components/ProspectTable.tsx");

  assert.match(table, /const countedExactly = exactTotal && exactTotal\.key === selectionKey \? exactTotal\.count : null;/);
  assert.match(table, /setExactTotal\(\{ key: selectionKey, count: set\.rowCount \}\);/);
  // Offered only where it fixes something: a total that stopped at its cap.
  assert.match(table, /\{totalCapped && countedExactly === null \? <button className="select-all-matching-button" disabled=\{countingAll\}/);
  // And the bulk path goes through the frozen selection.
  assert.match(table, /selectionMode === "all_matching"\s*\n\s*\? \(await runAllMatching\(action, targetClientId, requestId, dateContacted\)\)\.result \?\? \{\}/);
});

test("a database-wide action carries the pivot it was started under", async () => {
  const table = await read("../app/components/ProspectTable.tsx");
  const code = codeOnly(table);

  // The listing and the export both apply the Company DB pivot. Result sets did
  // not - they stored a search, a filter list and a client scope, so "all
  // matching" under a pivot froze everyone matching the filters: measured on
  // production, 681,085 rows where the screen said 7,047. Until 20260902000180
  // the answer was to refuse; now the pivot travels with the set, so the
  // refusals are gone and the scope has to reach every place that freezes one.
  assert.match(code, /const activeCompanyScope = scopeRestricts\(companyScope\) \? companyScope : null;/);
  assert.equal(code.match(/companyScope: activeCompanyScope/g)?.length, 2,
    "both buildResultSet calls must carry the pivot");
  assert.doesNotMatch(code, /scopeBlocksAllMatching|scopeRefusal/);
  // A selection made under one pivot must still not survive into another.
  assert.match(code, /const selectionKey = JSON\.stringify\(\{ clientId, search: search\.trim\(\), filters: filterPayload\(effectiveFilters\), companyScope \}\);/);
});

test("a pivot is part of a result set's identity, in three independent places", async () => {
  const [migration, lib, route] = await Promise.all([
    read("../supabase/migrations/20260902000180_carry_the_company_scope_into_a_result_set.sql"),
    read("../lib/result-sets.ts"),
    read("../app/api/result-sets/route.ts"),
  ]);
  const code = codeOnly(migration);

  // Two questions differing only by their pivot describe different people. If
  // identity ignored the pivot they would reuse each other's answer, which is
  // the same silent widening arriving through the cache instead of the query.
  // Three defences, deliberately not one, because the client-side hash is the
  // one most easily forgotten.
  assert.match(code, /md5\(company_scope::text\)/);          // the unique index
  assert.match(code, /and rs\.company_scope = v_company_scope/); // the reuse lookup
  assert.match(codeOnly(lib), /companyScope: input\.companyScope \?\? null/); // the hash
  assert.match(codeOnly(route), /companyScope: scopePayload/);

  // And the scope has to be applied when the set is built, not merely stored.
  assert.match(code, /eligible_companies as materialized \(select company_id from public\.company_scope_ids_v2/);
  assert.match(code, /join eligible_companies eligible on eligible\.company_id = pi\.company_id/);
  // Applied only when it narrows: a scope with neither search nor filters
  // matches every company, and joining a quarter of a million ids for that
  // would be pure cost.
  assert.match(code, /v_has_scope := v_scope <> '\{\}'::jsonb/);
});

test("company bulk domains reach the server as a set id, scoped to where they were pasted", async () => {
  const api = await read("../lib/dashboard-api.ts");
  // A path builder cannot store a list first, so the substitution happens in the
  // caller and arrives already encoded.
  assert.match(api, /function companyFilterParam\(filters: ProspectFilter\[\], encodedFilters: string\)/);
  assert.match(api, /const encoded = encodedFilters \|\| \(filters\.length \? encodeFilters\(filters\) : ""\);/);

  const companies = await read("../app/components/CompaniesWorkspace.tsx");
  assert.match(companies, /const requestFilters = JSON\.stringify\(await filterPayloadWithSets\(JSON\.parse\(encodedFilters\), "company", ""\)\);/);
  assert.match(companies, /encodedFilters: requestFilters/);

  const clients = await read("../app/components/ClientsPanel.tsx");
  // resolve_filter_set_v1 checks the client scope as well as the owner, so a set
  // built inside a client cannot be replayed against the global company DB.
  assert.match(clients, /filterPayloadWithSets\(JSON\.parse\(encodedFilters\), "company", client\.id\)/);
});

test("each worker bounds its own statements, because its functions cannot", async () => {
  // Measured on production 2026-09-02: `ALTER FUNCTION ... SET statement_timeout`
  // binds when the function is reached through PostgREST and does nothing on a
  // direct connection. A probe declaring 10s was cancelled at 10.004s over HTTP
  // and slept its full 20s through psql. Both workers connect directly, so
  // every declared timeout in their call path is decorative and the bound has
  // to be set on the connection.
  const operations = await read("../worker/operations-worker.mjs");
  assert.match(operations, /const statementTimeout = pgInterval\(process\.env\.OPERATIONS_STATEMENT_TIMEOUT, "120s", "OPERATIONS_STATEMENT_TIMEOUT"\);/);
  assert.match(operations, /await client\.query\(`set statement_timeout = '\$\{statementTimeout\}'`\);/);

  const imports = await read("../worker/import-worker.mjs");
  // 15s is right for the 250-row browser chunk and would fail every one of the
  // worker's 1,000-row batches, which measured 10.7-14.3s. So the worker sets a
  // bound sized for what it actually sends, rather than inheriting the role's
  // 15 minutes.
  assert.match(imports, /const batchTimeout = pgInterval\(process\.env\.IMPORT_BATCH_TIMEOUT, "120s", "IMPORT_BATCH_TIMEOUT"\);/);
  assert.match(imports, /await client\.query\(`set statement_timeout = '\$\{batchTimeout\}'`\);/);
  // Staging is a COPY of the whole file and stays generous.
  assert.match(imports, /const stagingTimeout = pgInterval\(process\.env\.IMPORT_STAGING_TIMEOUT, "10min", "IMPORT_STAGING_TIMEOUT"\);/);
  assert.doesNotMatch(codeOnly(imports), /set statement_timeout = '10min'/);
});

test("a timeout without a unit is refused, not silently read as milliseconds", async () => {
  // Postgres reads a bare `120` as 120ms. Left unchecked, a compose file typo
  // would cancel every batch instantly and present as a database fault.
  const { pgInterval } = await import("../worker/pg-interval.mjs");

  assert.equal(pgInterval(undefined, "120s", "X"), "120s");
  assert.equal(pgInterval("", "120s", "X"), "120s");
  assert.equal(pgInterval(" 5min ", "120s", "X"), "5min");
  for (const bad of ["120", "2 minutes", "abc", "-5s", "5sec"]) {
    assert.throws(() => pgInterval(bad, "120s", "X"), /must be a number with a unit/, `"${bad}" should be refused`);
  }
});

test("the worker runs operations without being able to decide what they are", async () => {
  const worker = await read("../worker/operations-worker.mjs");
  const code = codeOnly(worker);

  assert.match(code, /prospect_operations\.run_queue_unit_v1\(\$1,\$2,\$3\)/);
  assert.match(code, /prospect_operations\.expire_jobs_v1\(\)/);
  // It cannot enqueue or freeze - that belongs to a signed-in request.
  assert.doesNotMatch(code, /enqueue_v1|freeze_from/);
  // Still no PostgREST client: everything goes down its own connection.
  assert.doesNotMatch(code, /createClient|supabase/i);
  // Neither queue may starve the other.
  assert.match(code, /createFairScheduler\(\{ classes: \['search', 'operation', 'export'\]/);
});
