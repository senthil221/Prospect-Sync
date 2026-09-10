import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createAdmissionQueue } from "../lib/bounded-admission.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260911090000_bound_the_untimed_report_functions.sql";

test("the heavy report routes take a slot instead of running unguarded", async () => {
  const [duplicates, quality, coverage, dashboard] = await Promise.all([
    read("../app/api/duplicates/route.ts"),
    read("../app/api/data-quality/route.ts"),
    read("../app/api/coverage/route.ts"),
    read("../app/api/dashboard/route.ts"),
  ]);

  // These ran with no admission control at all, which is how one open tab
  // became everyone's outage on 2026-09-10 at 18:00 UTC.
  assert.ok(duplicates.includes("withAnalyticsSlot(request"));
  assert.ok(quality.includes("withAnalyticsSlot(request"));
  assert.ok(coverage.includes("withAnalyticsSlot(request"));
  // The dashboard is a page load at ~1.1s mean, not a report. It belongs in the
  // interactive queue; a two-slot analytics gate would make the landing page
  // queue behind someone's duplicate scan.
  assert.ok(dashboard.includes("withInteractiveSlot(request"));
  assert.ok(!dashboard.includes("withAnalyticsSlot"));

  // A refused slot must not be the only protection: the statement needs a
  // deadline too, or an abandoned request keeps its backend busy.
  assert.ok(duplicates.includes("abortSignal(request.signal"));
  assert.ok(quality.includes("abortSignal(signal)"));
  // And a timeout must read as a timeout, not as a crash.
  assert.ok(duplicates.includes("statementTimeoutResponse"));
  assert.ok(quality.includes("statementTimeoutResponse"));
});

test("analytics gets its own pool so a report cannot starve browsing", async () => {
  const admission = await read("../lib/admission.ts");

  // Worst case is now 8 interactive + 2 analytical = 10 of PostgREST's 24
  // connections. Eight concurrent 38-second duplicate scans would have held a
  // third of the pool for half a minute; two cannot.
  assert.ok(admission.includes("ANALYTICS_CONCURRENCY"));
  assert.ok(admission.includes("process.env.ANALYTICS_CONCURRENCY, 2, 1, 4"));
  assert.ok(admission.includes("process.env.INTERACTIVE_CONCURRENCY, 8, 1, 8"));
  assert.ok(admission.includes("export async function withAnalyticsSlot"));
  assert.ok(admission.includes("export async function withInteractiveSlot"));
});

test("a small pool queues work rather than dropping it", () => {
  // The feature has to keep working: a second caller waits for a slot, it is
  // not refused outright.
  const state = createAdmissionQueue(2, 8, 15_000).state();
  assert.equal(state.limit, 2);
  assert.equal(state.maxWaiting, 8);
  // Fifteen seconds, not the interactive two: a report is worth waiting in line
  // for, and refusing it after 2s would break a working feature to no purpose.
  assert.equal(state.waitMs, 15_000);
});

test("every ceiling is set above what the function actually takes", async () => {
  const migration = await read(migrationPath);

  // Set ABOVE each observed maximum, so nothing that works today starts
  // failing. The point is to stop a runaway holding a connection forever, not
  // to break a feature that legitimately takes half a minute.
  const ceilings = [
    ["find_duplicate_candidates(integer)", 120, 60.7],
    ["data_quality_overview()", 90, 34.2],
    ["analyze_prospect_index()", 120, 26.0],
    ["dashboard_workspace()", 30, 12.6],
    ["prospect_index_drift()", 90, 29.8],
  ];
  for (const [signature, seconds, observedMax] of ceilings) {
    const statement = "alter function public." + signature + " set statement_timeout = '" + seconds + "s'";
    assert.ok(migration.includes(statement), "missing: " + statement);
    assert.ok(seconds > observedMax, signature + ": " + seconds + "s must exceed the observed " + observedMax + "s");
  }
  // prospect_index_drift was 249ms from its old 30s ceiling - it would have
  // started failing on the next import, taking half the Data Quality tab.
  assert.ok(migration.includes("249ms from its own ceiling"));
  // ALTER, never CREATE OR REPLACE: a replace drops the body and can drift.
  assert.ok(!/create or replace function/i.test(migration));
  assert.ok(migration.includes("did not take its timeout"));
});

test("a database 500 records why, not just that it happened", async () => {
  const [errors, prospects] = await Promise.all([
    read("../lib/api-errors.ts"),
    read("../app/api/prospects/route.ts"),
  ]);

  assert.ok(errors.includes("export function databaseErrorResponse"));
  // The SQLSTATE is usually the whole answer, so it is kept beside the text.
  assert.ok(errors.includes("code: error?.code ?? null"));
  assert.ok(errors.includes("logServerEvent"));
  assert.ok(prospects.includes('return databaseErrorResponse("The prospect listing", error)'));
});
