import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { intentKey, pendingIntentCount, requestIdFor, settleIntent } from "../lib/request-intent.ts";

// Connecting the machinery Release 2 deployed. Everything below was reachable
// only from a psql prompt until now.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("a retry reuses its request id; a new intent gets a new one", () => {
  const push = intentKey({ action: "push", target: "client-1", selectionMode: "ids", ids: ["p2", "p1"] });

  const first = requestIdFor(push);
  // The retry after a dropped connection. Same intent, same id - otherwise the
  // server sees two requests and honours both, which is the double-push this
  // exists to prevent.
  assert.equal(requestIdFor(push), first);

  // The order rows were ticked in is not part of the intent.
  const reordered = intentKey({ action: "push", target: "client-1", selectionMode: "ids", ids: ["p1", "p2"] });
  assert.equal(reordered, push);
  assert.equal(requestIdFor(reordered), first);

  // A different target, selection or action is a different operation.
  for (const other of [
    intentKey({ action: "push", target: "client-2", selectionMode: "ids", ids: ["p1", "p2"] }),
    intentKey({ action: "push", target: "client-1", selectionMode: "ids", ids: ["p1", "p3"] }),
    intentKey({ action: "set_date_contacted", target: "client-1", selectionMode: "ids", ids: ["p1", "p2"] }),
  ]) {
    assert.notEqual(requestIdFor(other), first);
  }

  // Settled only on success: the next deliberate push of the same selection is
  // a second operation and must not be swallowed as a replay.
  settleIntent(push);
  assert.notEqual(requestIdFor(push), first);
  assert.ok(pendingIntentCount() > 0);
});

test("the push action sends an intent-stable id, not a per-click one", async () => {
  const table = await read("../app/components/ProspectTable.tsx");

  assert.match(table, /const requestId = requestIdFor\(key\);/);
  assert.match(table, /body: JSON\.stringify\(\{ action, requestId,/);
  // Settled after the call returns, never in a catch - a failed attempt must
  // keep its id so the retry is recognised.
  assert.match(table, /settleIntent\(key\);/);
  // The giveaway that this was done wrong would be generating the id inline.
  assert.doesNotMatch(table, /requestId: crypto\.randomUUID\(\)/);
});

test("a big pasted list becomes a set, a small one does not", async () => {
  const client = await read("../lib/filter-set-client.ts");

  assert.match(client, /const setThreshold = 500;/);
  assert.match(client, /entry\.operator !== "equals" \|\| !\("values" in entry\) \|\| entry\.values\.length < setThreshold\) return entry;/);
  assert.match(client, /"\/api\/filter-sets"/);
  // Content-keyed, so re-fetching the grid does not re-upload the same list.
  assert.match(client, /const knownSets = new Map<string, string>\(\);/);
  // Any failure falls back to inline values: slower, never wrong.
  assert.match(client, /\} catch \{\s*\n\s*\/\/ Sending the values inline still works\./);
});

test("a set id changes the transport, never the cache identity", async () => {
  const workspace = await read("../app/components/ProspectsWorkspace.tsx");

  // Section 4.1: "filter-set UUIDs no longer affect logical identity". The
  // count cache key must stay on the plain encoding, or the same question asked
  // with a set id would miss the count it already has.
  // Derived from the encoding, not from the filter array. Depending on both
  // would re-fetch whenever the parent rebuilt the array even though the
  // question had not changed - a real lint warning, not a style note.
  assert.match(workspace, /const requestFilters = JSON\.stringify\(await filterPayloadWithSets\(JSON\.parse\(encodedFilters\), "prospect", ""\)\);/);
  assert.match(workspace, /filters: requestFilters/);
  assert.match(workspace, /const countKey = useMemo\(\(\) => JSON\.stringify\(\[debouncedSearch\.trim\(\), encodedFilters/);
  assert.match(workspace, /must not affect logical\s*\n\s*\/\/ identity/);
});
