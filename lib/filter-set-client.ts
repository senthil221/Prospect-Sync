import { api } from "./dashboard-api.ts";
import { BoundedCache } from './bounded-cache.ts';

// Turn a big pasted value list into a durable set, once, and then send its id.
//
// Without this the values travel with every request: the page, the count, each
// later page, the pivot and every export page. At 5,000 values that is roughly
// 75 KB per request and 82 KB of compiled SQL (measured in 20260902000100).
// With it, the request carries a uuid.
//
// BELOW THE THRESHOLD, NOTHING CHANGES. A handful of values costs nothing to
// send and a round trip to store, so only lists big enough to matter become
// sets. 500 is where the payload starts to be worth a request of its own; the
// UI already switches to exact matching at 25 (lib/bulk-values.ts), which is a
// different decision about semantics rather than about size.
const setThreshold = 500;

// Content-keyed, so the same pasted list is stored once per session however
// many times the grid re-fetches. The server is idempotent on the same
// identity too, so a miss here costs a request, never a duplicate set.
const knownSets = new BoundedCache<string>(40, 1024 * 1024);
let setCacheGeneration = 0;

function cacheKey(entityType: string, clientScope: string, field: string, values: string[]) {
  return JSON.stringify([entityType, clientScope, field, [...values].sort()]);
}

// What the wire carries: either the values inline, or the id of a stored set.
// parseFilters on the server accepts both (lib/prospect-filters.ts).
export type WireFilter =
  | { field: string; operator: string; values: string[]; scopes?: string[] }
  | { field: string; operator: string; setId: string };

// Replace large exact-value lists with set ids. Returns the payload to send.
//
// Falls back to the inline values whenever anything goes wrong - a failed
// request, a migration not yet applied, an unexpected shape. The fallback is
// exactly today's behaviour, so this can never make a filter stop working; the
// worst case is that it stays as slow as it is now.
// Takes the already-encoded payload rather than the filter objects, so a caller
// can depend on the encoding alone. That matters in a React effect: depending
// on the filter array as well would re-run the fetch whenever the parent
// rebuilt it, even when the encoding - the actual question - had not changed.
export async function filterPayloadWithSets(
  plain: WireFilter[],
  entityType: "prospect" | "company",
  clientScope = "",
): Promise<WireFilter[]> {
  const sizeOf = (entry: WireFilter) => ("values" in entry ? entry.values.length : 0);
  const needsSet = plain.some((entry) => entry.operator === "equals" && sizeOf(entry) >= setThreshold);
  if (!needsSet) return plain;

  return Promise.all(plain.map(async (entry) => {
    if (entry.operator !== "equals" || !("values" in entry) || entry.values.length < setThreshold) return entry;
    const filter = entry;

    const key = cacheKey(entityType, clientScope, filter.field, filter.values);
    const generation = setCacheGeneration;
    const known = knownSets.get(key);
    if (known) return { field: filter.field, operator: filter.operator, setId: known };

    try {
      const created = await api<{ setId: string }>("/api/filter-sets", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ entityType, field: filter.field, clientScope, values: filter.values }),
      });
      if (!created?.setId) return entry;
      if (generation === setCacheGeneration) knownSets.set(key, created.setId);
      return { field: filter.field, operator: filter.operator, setId: created.setId };
    } catch {
      // Sending the values inline still works. Slower, never wrong.
      return entry;
    }
  }));
}

// A set that has expired or been cleaned up must not be retried forever: the
// server answers 403 for one it cannot resolve, and the caller drops it so the
// next request rebuilds from the values it still holds locally.
export function forgetFilterSets() {
  setCacheGeneration++;
  knownSets.clear();
}

export function knownFilterSetCount() {
  return knownSets.size;
}
