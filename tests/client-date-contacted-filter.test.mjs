import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { parseFilters } from "../lib/prospect-filters.ts";
import { contactDateChip } from "../lib/dashboard-helpers.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const filter = (operator, values) => JSON.stringify([{ field: "__client_date_contacted", operator, values }]);

test("Date Contacted takes the client id, then calendar dates", () => {
  assert.deepEqual(parseFilters(filter("between", ["client-1", "2026-09-01", "2026-09-30"]))[0].values, ["client-1", "2026-09-01", "2026-09-30"]);
  assert.equal(parseFilters(filter("never", ["client-1"]))[0].operator, "never");
  assert.equal(parseFilters(filter("on", ["client-1", "2026-09-15"]))[0].values.length, 2);
  // The same day on both ends is a one-day range.
  assert.equal(parseFilters(filter("between", ["client-1", "2026-09-15", "2026-09-15"])).length, 1);
});

test("a malformed Date Contacted filter is refused, never widened", () => {
  assert.throws(() => parseFilters(filter("between", ["client-1", "2026-09-01"])), /needs the client and 2 dates/);
  assert.throws(() => parseFilters(filter("on", ["client-1"])), /needs the client and 1 date/);
  assert.throws(() => parseFilters(filter("on", ["client-1", "15/09/2026"])), /calendar dates/);
  assert.throws(() => parseFilters(filter("on", ["client-1", "2026-02-30"])), /calendar dates/);
  assert.throws(() => parseFilters(filter("between", ["client-1", "2026-09-30", "2026-09-01"])), /on or after the "from" date/);
  assert.throws(() => parseFilters(filter("contains", ["client-1"])), /Date Contacted requires a date operator/);
  // Date operators stay limited to the two date fields.
  assert.throws(() => parseFilters(JSON.stringify([{ field: "__company", operator: "before", values: ["x"] }])), /only available for Last Verified and Date Contacted/);
});

test("the chip reads as a range, not as raw values", () => {
  // Month abbreviations depend on the runtime's locale data, so only the shape is fixed.
  assert.match(contactDateChip("between", ["c", "2026-09-01", "2026-09-30"]), /^1 \S+ 2026 – 30 \S+ 2026$/);
  assert.equal(contactDateChip("never", ["c"]), "Never contacted");
  assert.match(contactDateChip("after", ["c", "2026-09-01"]), /^On or after 1 /);
});

test("the builder and the row matcher both learn the field, from client_prospects.date_added", async () => {
  const migration = await read("../supabase/migrations/20261001090000_people_filter_by_client_date_contacted.sql");
  assert.ok(migration.includes("$old$    if field_key in ('__lead', '__contactable') then$old$"));
  assert.ok(migration.includes("$old$      when filter_item->>'field' = '__lead' then ($old$"));
  assert.match(migration, /where cp\.prospect_id = pi\.id and cp\.client_id = %L and %s/);
  assert.match(migration, /when 'between' then case when cardinality\(raw_values\) >= 3\s+then format\('cp\.date_added between %L::date and %L::date'/);
  assert.match(migration, /when 'between' then cp\.date_added between \(filter_item->'values'->>1\)::date/);
  assert.match(migration, /Date Contacted proof passed on % people/);
});

test("the filter appears only inside a client, under Contact history", async () => {
  const panel = await read("../app/ApolloFilterPanel.tsx");
  assert.match(panel, /\{clientId && "date contacted cooldown"\.includes\(normalizedSearch\) \? <div className="apollo-filter-group">\s+<small>Contact history<\/small>\{renderDefinition\(contactDateFilter\)\}/);
  assert.match(panel, /const values = operator === "never" \? \[clientId\] : operator === "between" \? \[clientId, start, end\] : \[clientId, start\];/);
  const table = await read("../app/components/ProspectTable.tsx");
  assert.match(table, /if \(filter\.field === "__client_date_contacted"\) return \[<button key=\{filter\.id\}/);
});
