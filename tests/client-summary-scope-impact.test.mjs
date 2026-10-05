import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import typescript from "typescript";
import { boundedDatabaseAbortResponse, databaseErrorResponse } from "../lib/api-errors.ts";
import {
  clientSummaryPhaseOutcome,
  clientSummarySignals,
  observeClientSummaryQuery,
} from "../lib/client-summary-query.ts";
import {
  observabilitySnapshot,
  recordClientSummaryPhase,
  resetObservability,
} from "../lib/observability.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

async function instrumentRoute(path, functionName, mocks) {
  const source = await read(path);
  const marker = `async function ${functionName}`;
  assert.ok(source.includes(marker), `${functionName} remains an internal route helper`);
  const instrumented = source.replace(marker, `export async function ${functionName}`);
  const javascript = typescript.transpileModule(instrumented, {
    compilerOptions: { module: typescript.ModuleKind.CommonJS, target: typescript.ScriptTarget.ES2022 },
  }).outputText;
  const routeModule = { exports: {} };
  const execute = vm.runInThisContext(`(function(exports, require, module) { ${javascript}\n})`, { filename: path });
  execute(routeModule.exports, (specifier) => {
    if (specifier in mocks) return mocks[specifier];
    throw new Error(`Unexpected route dependency: ${specifier}`);
  }, routeModule);
  return routeModule.exports[functionName];
}

function query(result) {
  return {
    select() { return this; },
    eq() { return this; },
    maybeSingle() { return this; },
    order() { return this; },
    abortSignal() { return result instanceof Error ? Promise.reject(result) : Promise.resolve(result); },
  };
}

function routeMocks(prefix) {
  const observed = { observed: (_route, handler) => handler };
  return {
    [`${prefix}/auth`]: { authorizeApi: async () => null },
    [`${prefix}/api-errors.ts`]: { boundedDatabaseAbortResponse, databaseErrorResponse },
    [`${prefix}/client-summary-query.ts`]: { clientSummarySignals, observeClientSummaryQuery },
    [`${prefix}/supabase/admin`]: { createAdminClient: () => ({}) },
    [`${prefix}/observability`]: observed,
    [`${prefix}/observability.ts`]: observed,
  };
}

const liveSignals = (callerSignal) => {
  const live = new AbortController().signal;
  return { callerSignal, deadlineSignal: live, signal: callerSignal };
};

test("client summary outcomes distinguish caller cancellation, deadlines and database failures", () => {
  const live = new AbortController().signal;
  const caller = AbortSignal.abort(new DOMException("caller", "AbortError"));
  const deadline = AbortSignal.abort(new DOMException("deadline", "AbortError"));

  assert.equal(clientSummaryPhaseOutcome(null, caller, live), "cancelled");
  assert.equal(clientSummaryPhaseOutcome(new DOMException("deadline", "AbortError"), live, deadline), "timed_out");
  assert.equal(clientSummaryPhaseOutcome({ code: "57014", message: "statement timeout" }, live, live), "timed_out");
  assert.equal(clientSummaryPhaseOutcome(new DOMException("left page", "AbortError"), live, live), "cancelled");
  assert.equal(clientSummaryPhaseOutcome({ code: "25P02", message: "transaction is aborted" }, live, live), "error");
  assert.equal(clientSummaryPhaseOutcome(null, live, live), "ok");
});

test("the combined client summary signal follows its caller", () => {
  const caller = new AbortController();
  const signals = clientSummarySignals(caller.signal, 60_000);
  assert.equal(signals.signal.aborted, false);
  caller.abort();
  assert.equal(signals.signal.aborted, true);
  assert.equal(signals.callerSignal.aborted, true);
});

test("client summary phase metrics execute real PromiseLike work with bounded private labels", async () => {
  resetObservability();
  const live = new AbortController().signal;
  const result = await observeClientSummaryQuery(
    "single",
    "counts",
    Promise.resolve({ data: [{ id: "private-client" }], error: null }),
    live,
    live,
  );
  assert.equal(result.data.length, 1);
  recordClientSummaryPhase("private-client", "private-phase", "ok", 1, 1);

  const phases = observabilitySnapshot().queryPhases;
  assert.deepEqual(phases.totals, { "client_summary_single:counts:ok": 1 });
  assert.deepEqual(phases.rowBuckets["client_summary_single:counts:ok"], { "1-10": 1 });
  assert.doesNotMatch(JSON.stringify(phases), /private-client|private-phase/);
  resetObservability();
});

test("bounded client summary responses map caller, deadline and SQL timeout without masking other errors", async () => {
  const live = new AbortController().signal;
  const caller = AbortSignal.abort();
  const deadline = AbortSignal.abort();
  const options = { subject: "This client summary", alternative: "Return to Clients." };

  const cancelled = boundedDatabaseAbortResponse({ ...options, callerSignal: caller, deadlineSignal: live });
  assert.equal(cancelled?.status, 499);
  const timedOut = boundedDatabaseAbortResponse({ ...options, callerSignal: live, deadlineSignal: deadline,
    error: new DOMException("deadline", "AbortError") });
  assert.ok(timedOut);
  assert.equal(timedOut.status, 504);
  assert.equal((await timedOut.json()).code, "statement_timeout");
  const databaseTimeout = boundedDatabaseAbortResponse({ ...options, callerSignal: live, deadlineSignal: live,
    error: { code: "57014", message: "canceling statement due to statement timeout" } });
  assert.equal(databaseTimeout?.status, 504);
  assert.equal(boundedDatabaseAbortResponse({ ...options, callerSignal: live, deadlineSignal: live,
    error: { code: "25P02", message: "transaction is aborted" } }), null);
});

test("the migration scopes only single-client misses and never publishes a partial cache", async () => {
  const migration = await read("../supabase/migrations/20261005073357_scope_single_client_summary_cache_miss.sql");
  assert.match(migration, /set local lock_timeout = '5s';/);
  assert.match(migration, /elsif p_client_id is not null then/);
  assert.match(migration, /from public\.client_summaries s\s+where s\.id = p_client_id;/);
  const scopedBranch = migration.split("elsif p_client_id is not null then")[1].split("  else")[0];
  assert.doesNotMatch(scopedBranch, /insert into public\.client_summary_cache|update public\.client_summary_cache|delete from public\.client_summary_cache/);
  assert.match(migration, /lower\(pg_get_functiondef/);
  assert.match(migration, /revoke execute on function public\.client_summaries_v1\(text\) from public, anon, authenticated;/);
  assert.match(migration, /grant execute on function public\.client_summaries_v1\(text\) to service_role;/);
});

test("both client GET routes apply the same deadline, error and redacted timing contract", async () => {
  const [directory, detail] = await Promise.all([
    read("../app/api/clients/route.ts"),
    read("../app/api/clients/[id]/route.ts"),
  ]);
  for (const route of [directory, detail]) {
    assert.match(route, /signals: clientSummarySignals/);
    assert.match(route, /dependencies\.signals\(request\.signal\)/);
    assert.match(route, /observeClientSummaryQuery\(/);
    assert.match(route, /\.abortSignal\(signal\)/);
    assert.match(route, /boundedDatabaseAbortResponse\(/);
    assert.match(route, /databaseErrorResponse\(/);
  }
  assert.match(directory, /observeClientSummaryQuery\("directory", "counts"/);
  assert.match(detail, /observeClientSummaryQuery\("single", "counts"/);
  assert.match(detail, /from\("client_folders"\)[\s\S]*?\.abortSignal\(signal\)/);
  assert.doesNotMatch(`${directory}\n${detail}`, /recordClientSummaryPhase\([^)]*\bid\b/);
});

test("client GET handlers authorize before database work and return their real success fields", async () => {
  const directoryMocks = {
    ...routeMocks("../../../lib"),
    "../../../db/normalize": { normalizeText: (value) => value },
  };
  const detailMocks = {
    ...routeMocks("../../../../lib"),
    "../../../../lib/delete-cleanup.ts": { deleteAndReindex() {}, queuedNotice() {} },
  };
  const directory = await instrumentRoute("../app/api/clients/route.ts", "getClientDirectory", directoryMocks);
  const detail = await instrumentRoute("../app/api/clients/[id]/route.ts", "getClientDetail", detailMocks);

  let adminCalls = 0;
  const unauthorized = await directory(new Request("https://example.test/api/clients"), {
    authorize: async () => new Response(null, { status: 401 }),
    admin: () => { adminCalls += 1; return {}; },
    signals: liveSignals,
  });
  assert.equal(unauthorized.status, 401);
  assert.equal(adminCalls, 0);

  const summary = { id: "client-a", name: "Client A", folder_id: "folder-a", prospect_count: 3 };
  const directoryAdmin = {
    rpc: () => query({ data: [summary], error: null }),
    from: (table) => table === "client_settings"
      ? query({ data: [{ client_id: "client-a", cooldown_days: 30, seg_emails: "discard" }], error: null })
      : query({ data: [{ id: "folder-a", name: "North" }], error: null }),
  };
  const directoryResponse = await directory(new Request("https://example.test/api/clients"), {
    authorize: async () => null,
    admin: () => directoryAdmin,
    signals: liveSignals,
  });
  assert.equal(directoryResponse.status, 200);
  assert.deepEqual((await directoryResponse.json()).clients[0], {
    ...summary, cooldown_days: 30, seg_emails: "discard", folder_name: "North",
  });

  const detailAdmin = {
    rpc: () => query({ data: [summary], error: null }),
    from: (table) => table === "client_settings"
      ? query({ data: { cooldown_days: 45, seg_emails: "keep" }, error: null })
      : table === "clients"
        ? query({ data: { folder_id: "folder-a" }, error: null })
        : query({ data: { name: "North" }, error: null }),
  };
  const detailResponse = await detail(new Request("https://example.test/api/clients/client-a"),
    { params: Promise.resolve({ id: "client-a" }) }, {
      authorize: async () => null,
      admin: () => detailAdmin,
      signals: liveSignals,
    });
  assert.equal(detailResponse.status, 200);
  assert.deepEqual((await detailResponse.json()).client, {
    ...summary, cooldown_days: 45, seg_emails: "keep", folder_name: "North",
  });
});

test("client GET handlers map SQL deadlines, caller cancellation, folder deadlines and real database failures", async () => {
  const directory = await instrumentRoute("../app/api/clients/route.ts", "getClientDirectory", {
    ...routeMocks("../../../lib"),
    "../../../db/normalize": { normalizeText: (value) => value },
  });
  const detail = await instrumentRoute("../app/api/clients/[id]/route.ts", "getClientDetail", {
    ...routeMocks("../../../../lib"),
    "../../../../lib/delete-cleanup.ts": { deleteAndReindex() {}, queuedNotice() {} },
  });
  const database = (summaryResult) => ({
    rpc: () => query(summaryResult),
    from: () => query({ data: [], error: null }),
  });

  const timeout = await directory(new Request("https://example.test/api/clients"), {
    authorize: async () => null,
    admin: () => database({ data: null, error: { code: "57014", message: "statement timeout" } }),
    signals: liveSignals,
  });
  assert.equal(timeout.status, 504);

  const caller = new AbortController();
  caller.abort();
  const cancelled = await directory(new Request("https://example.test/api/clients", { signal: caller.signal }), {
    authorize: async () => null,
    admin: () => database(new DOMException("left", "AbortError")),
    signals: liveSignals,
  });
  assert.equal(cancelled.status, 499);

  const deadline = AbortSignal.abort(new DOMException("deadline", "AbortError"));
  const detailAdmin = {
    rpc: () => query({ data: [{ id: "client-a", name: "Client A", folder_id: "folder-a" }], error: null }),
    from: (table) => table === "client_folders"
      ? query(new DOMException("deadline", "AbortError"))
      : query({ data: table === "clients" ? { folder_id: "folder-a" } : {}, error: null }),
  };
  const folderTimeout = await detail(new Request("https://example.test/api/clients/client-a"),
    { params: Promise.resolve({ id: "client-a" }) }, {
      authorize: async () => null,
      admin: () => detailAdmin,
      signals: (callerSignal) => ({ callerSignal, deadlineSignal: deadline, signal: deadline }),
    });
  assert.equal(folderTimeout.status, 504);

  const failed = await directory(new Request("https://example.test/api/clients"), {
    authorize: async () => null,
    admin: () => database({ data: null, error: { code: "25P02", message: "transaction is aborted" } }),
    signals: liveSignals,
  });
  assert.equal(failed.status, 500);
  assert.match((await failed.json()).error, /transaction is aborted/);
});
