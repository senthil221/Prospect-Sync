import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { filterSetIds, maxFilterValues, parseFilters } from "../lib/prospect-filters.ts";

// Release 2, item 1 wiring: a request carries a set id, the compilers turn it
// into a membership test, and ownership is re-checked every time it is used.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const uuid = "11111111-1111-1111-1111-111111111111";

test("a set-backed filter parses without carrying values", () => {
  const [filter] = parseFilters(JSON.stringify([
    { field: "__company_domain", operator: "equals", setId: uuid },
  ]));
  assert.equal(filter.setId, uuid);
  assert.deepEqual(filter.values, []);
  assert.deepEqual(filterSetIds([filter]), [uuid]);

  // The size caps do not apply to a set: nothing is being carried, which is the
  // entire point. A list this long inline would be refused with 413.
  const inline = Array.from({ length: maxFilterValues + 1 }, (_, index) => `v${index}`);
  assert.throws(() => parseFilters(JSON.stringify([{ field: "__website", operator: "equals", values: inline }])));
  assert.equal(parseFilters(JSON.stringify([{ field: "__website", operator: "equals", setId: uuid }])).length, 1);
});

test("a malformed or misused set id is refused without dropping its restriction", () => {
  // Not a uuid: never reaches SQL, where it would be cast and raise.
  assert.throws(() => parseFilters(JSON.stringify([
    { field: "__company_domain", operator: "equals", setId: "not-a-uuid' or 1=1--" },
  ])), /valid ID/);
  // A set expresses equality only, matching what the compilers emit.
  assert.throws(() => parseFilters(JSON.stringify([
    { field: "__company_domain", operator: "contains", setId: uuid },
  ])), /equality/);
  // And an ordinary filter still parses normally alongside.
  const parsed = parseFilters(JSON.stringify([
    { field: "__title", operator: "contains", values: ["vp"] },
    { field: "__company_domain", operator: "equals", setId: uuid },
  ]));
  assert.equal(parsed.length, 2);
  assert.deepEqual(filterSetIds(parsed), [uuid]);
});

test("ownership is re-checked on every use, not inferred from the id", async () => {
  const helper = await read("../lib/filter-sets.ts");

  assert.match(helper, /resolve_filter_set_v1/);
  assert.match(helper, /p_owner_id: ownerId/);
  assert.match(helper, /status: 403/);
  // A genuine fault must not be reported as "not yours", or a broken database
  // looks like a permissions problem.
  assert.match(helper, /if \(error\.code === "P0002"\)/);
  assert.match(helper, /return Response\.json\(\{ error: error\.message \}, \{ status: 500 \}\)/);
  // One message for missing, not-yours and expired.
  assert.match(helper, /class FilterSetAccessError/);

  // Every route that accepts filters and reads data checks before querying.
  for (const path of [
    "../app/api/prospects/route.ts",
    "../app/api/companies/route.ts",
    "../app/api/prospects/export/route.ts",
  ]) {
    const source = await read(path);
    assert.match(source, /authorizeFilterSets\(/, `${path} must authorize filter sets`);
    // The export route answers through a helper that records the outcome, so
    // the refusal reads `return answer(setDenial)` there and `return setDenial`
    // everywhere else. Either way it is returned before anything is queried.
    assert.match(source, /if \(setDenial\) return (?:answer\()?setDenial/, `${path} must refuse on denial`);
  }
});

test("the create endpoint owns the set to the signed-in user", async () => {
  const route = await read("../app/api/filter-sets/route.ts");

  // The owner is the session, never the request body - otherwise the ownership
  // check on every later use proves nothing.
  assert.match(route, /const user = await getAuthorizedUser\(\);/);
  assert.match(route, /p_owner_id: user\.id/);
  assert.doesNotMatch(route, /payload\.owner/);

  // 10,000 here versus 5,000 inline: the higher ceiling is what the mechanism
  // is for. Over it is refused, not trimmed.
  assert.match(route, /const maxSetValues = 10_000;/);
  assert.match(route, /status: 413/);
  assert.doesNotMatch(route, /\.slice\(0, maxSetValues\)/);

  // The content hash goes back to the caller, because that is what the count
  // cache keys on rather than the random id.
  assert.match(route, /contentHash: row\.content_hash/);
  assert.match(route, /reused: row\.reused === true/);
});

test("the compilers gain a set arm and keep their splices loud", async () => {
  const migration = await read("../supabase/migrations/20260902000110_compile_filter_sets_into_predicates.sql");

  // Both compilers, both anchors checked for being present exactly once.
  assert.match(migration, /prospect_filter_sql_v1: expected exactly one splice anchor/);
  assert.match(migration, /company_filter_sql_v2: expected exactly one splice anchor/);
  // The bug the self-check found: a set-backed filter has no values, and the
  // company compiler skipped valueless filters, widening the predicate to true.
  assert.match(migration, /company_filter_sql_v2: expected exactly one empty-values guard/);
  assert.match(migration, /widens to true/);

  // The migration proves its own splices in the transaction that made them.
  assert.match(migration, /does not compile a filter set/);
  assert.match(migration, /a non-uuid setId was accepted/);

  // The cast is the injection guard.
  assert.match(migration, /\(filter_item->>\\?'setId\\?'\)::uuid/);

  // The public wrappers exist because PostgREST only sees `public`, and stay
  // service-role only.
  assert.match(migration, /revoke execute on function public\.create_filter_set_v1\(text, text, text, text, text\[\]\) from public, anon, authenticated;/);
  assert.match(migration, /revoke execute on function public\.resolve_filter_set_v1\(uuid, text, text, text\) from public, anon, authenticated;/);
  assert.match(migration, /grant execute on function public\.create_filter_set_v1\(text, text, text, text, text\[\]\) to service_role;/);
  assert.match(migration, /grant execute on function public\.resolve_filter_set_v1\(uuid, text, text, text\) to service_role;/);
});
