import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseRequestId, selectionContentHash } from "../lib/operation-jobs.ts";

// Release 2, item 4: sections 9.2 and 9.3. A retry cannot double-apply, and a
// selection cannot widen between choosing and running.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000140_idempotent_frozen_operations.sql");
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("idempotency is keyed on the request, never on the content", async () => {
  const sql = executable(await migration());

  // Section 9.2 says this in as many words: "Never deduplicate solely by
  // content hash." Two identical pushes a week apart are two operations.
  assert.match(sql, /create unique index if not exists uq_operation_jobs_request\s*\n\s*on prospect_operations\.operation_jobs \(actor, action, request_id\);/);
  // The content hash exists, as an audit field beside the key rather than as it.
  assert.match(sql, /content_hash text not null/);
  assert.doesNotMatch(sql, /unique index[^;]*\(content_hash\)/);
  // A missing request id is refused with a reason, not silently tolerated in SQL.
  assert.match(sql, /An operation needs a client-generated request id/);
});

test("a hash is stable under reordering but not under real change", () => {
  const base = {
    action: "push", clientScope: "c1", search: " vp ",
    filters: [{ field: "__title", operator: "contains", values: ["vp"] }],
    prospectIds: ["p2", "p1"], excludedIds: ["x1"],
  };
  const reordered = { ...base, prospectIds: ["p1", "p2"] };
  assert.equal(selectionContentHash(base), selectionContentHash(reordered),
    "the order rows were ticked in must not change the hash");

  assert.notEqual(selectionContentHash(base), selectionContentHash({ ...base, action: "remove" }));
  assert.notEqual(selectionContentHash(base), selectionContentHash({ ...base, excludedIds: [] }));
  assert.notEqual(selectionContentHash(base), selectionContentHash({ ...base, clientScope: "c2" }));
});

test("only a well-formed request id is accepted", () => {
  assert.equal(parseRequestId("55555555-5555-5555-5555-555555555555"), "55555555-5555-5555-5555-555555555555");
  assert.equal(parseRequestId("  55555555-5555-5555-5555-555555555555  "), "55555555-5555-5555-5555-555555555555");
  for (const bad of ["", "not-a-uuid", 12345, null, undefined, {}, "55555555"]) {
    assert.equal(parseRequestId(bad), null, `${String(bad)} must not be accepted`);
  }
});

test("a frozen selection cannot expand, and batches are individually retry-safe", async () => {
  const sql = executable(await migration());

  // Freezing twice is a no-op rather than an append - verified on production by
  // freezing three ids and then re-freezing six.
  assert.match(sql, /if v_row\.status <> 'pending' then\s*\n\s*return query select v_row\.total_items, v_row\.excluded_count;/);
  // Exclusions are subtracted at freeze time and counted.
  assert.match(sql, /where not \(entity_id = any \(v_row\.excluded_ids\)\)/);
  // Only unapplied items are ever handed out, which is what makes a crash
  // mid-operation resumable rather than repeatable.
  assert.match(sql, /where i\.job_id = p_job_id and i\.applied_at is null/);
  assert.match(sql, /and i\.applied_at is null\s*\n\s*and i\.entity_id = any/);
  // A half-built result set must not be frozen into a job.
  assert.match(sql, /That result set is still being built/);
});

test("the route replays instead of re-running, and freezes what it can", async () => {
  const route = await read("../app/api/clients/[id]/prospects/route.ts");

  assert.match(route, /const requestId = parseRequestId\(payload\.requestId\)/);
  assert.match(route, /if \(operation\.kind === "replay"\)/);
  assert.match(route, /replayed: true/);
  // The explicit selection is frozen before the mutation runs.
  assert.match(route, /await freezeSelection\(supabase, operation\.jobId, actor, selection\.prospectIds\)/);
  // And the answer is recorded so the replay has something to return.
  assert.match(route, /recordOperationResult/);
});

test("tracking failing must never take the mutation down with it", async () => {
  const helper = await read("../lib/operation-jobs.ts");
  // An idempotency layer that can break the thing it protects is worse than
  // none: on failure the operation runs unprotected, which is today's behaviour.
  assert.match(helper, /operation_tracking_unavailable/);
  assert.match(helper, /return \{ kind: "untracked" \};/);
  // A request with no id is not refused, because the UI is still being taught
  // to send one and the authenticated import test does not.
  assert.match(helper, /if \(!input\.requestId \|\| !input\.actor\) return \{ kind: "untracked" \};/);
});

test("the worker may drive operations but never start or freeze one", async () => {
  const sql = await migration();

  for (const granted of [
    "prospect_operations.claim_next_v1\\(text, integer\\)",
    "prospect_operations.next_batch_v1\\(uuid, integer\\)",
    "prospect_operations.mark_applied_v1\\(uuid, text\\[\\]\\)",
    "prospect_operations.expire_jobs_v1\\(\\)",
  ]) {
    assert.match(sql, new RegExp(`grant execute on function ${granted} to prospect_operator;`));
  }
  // Enqueue and freeze belong to a signed-in request; the migration asserts the
  // worker cannot reach them, in the transaction that grants everything else.
  // The apostrophe is doubled in the SQL literal, as SQL requires.
  assert.match(sql, /the worker can enqueue an operation on a user''s behalf/);
  assert.match(sql, /the worker can freeze a selection/);
  assert.match(sql, /the worker can read frozen ids directly/);
});
