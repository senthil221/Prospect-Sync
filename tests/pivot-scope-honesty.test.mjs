import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");

// "See People" and "See Companies" always sent a scope, even from an unfiltered
// tab: {"search":"","filters":[],"limit":250000}. Since 20260901000010 the
// workspace functions correctly ignore a scope that restricts nothing -- an
// unfiltered pivot means "everyone" -- but the UI still rendered the cross-scope
// banner, so the pivot showed every row under a banner claiming it was scoped.
// That reads as broken even though the rows are right.
test("a pivot only carries a scope that narrows something", async () => {
  const [scopes, dashboard] = await Promise.all([
    read("../lib/workspace-scopes.ts"),
    read("../app/DashboardApp.tsx"),
  ]);

  assert.match(scopes, /export function scopeRestricts/);
  // Restricting means a search term or at least one filter -- the limit alone
  // never narrows anything, and it is always present.
  assert.match(scopes, /scope\.search\.trim\(\) !== "" \|\| scope\.filters\.length > 0/);

  assert.match(dashboard, /import \{ scopeRestricts,/);
  assert.match(dashboard, /setCompanyPeopleScope\(scopeRestricts\(scope\) \? scope : null\)/);
  assert.match(dashboard, /setPeopleCompanyScope\(scopeRestricts\(scope\) \? scope : null\)/);
});

// The banner is driven by the scope being non-null, so clearing the scope is what
// removes the false claim. Guard the coupling so a later refactor cannot
// reintroduce a banner for an empty scope.
test("the cross-scope banner is driven by the scope itself", async () => {
  const table = await read("../app/components/ProspectTable.tsx");
  assert.match(table, /\{companyScope \? <div className=\{`cross-scope-banner/);
  assert.match(table, /scopeCapped \? "capped" : ""/);
});
