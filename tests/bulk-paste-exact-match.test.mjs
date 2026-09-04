import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Pasting a list of values means "these exact values". Substring matching is both
// wrong and unindexable: 781 pasted domains matched 5,904 companies (acme.com is a
// substring of notacme.com.au), and above bulk_or_threshold the prefilter emits a
// correlated EXISTS that no index can serve -- 127,358 ms end to end on the live
// database, against 166 ms once the operator is equals.
//
// exactMatchThreshold existed with a comment describing exactly this, and was
// imported nowhere for the life of the feature. These assertions exist so it
// cannot quietly become dead code again.

test("both bulk paste paths switch to exact matching above the threshold", async () => {
  const [bulkValues, peoplePanel, companyPanel] = await Promise.all([
    readFile(new URL("../lib/bulk-values.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/CompanyFilterPanel.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(bulkValues, /export const exactMatchThreshold/);

  // Both panels must take the decision from lib/bulk-values, not re-declare a
  // number of their own. It is switchesToExactMatch rather than the bare
  // threshold now, because the rule is field-aware: a keyword search never
  // switches (tests/keyword-search-never-exact.test.mjs). The point of this
  // assertion is unchanged -- the decision lives in one place.
  assert.match(peoplePanel, /import \{[^}]*switchesToExactMatch[^}]*\} from "\.\.\/lib\/bulk-values"/);
  assert.match(companyPanel, /import \{[^}]*switchesToExactMatch[^}]*\} from "\.\.\/lib\/bulk-values"/);

  // People panel: include and exclude both flip, so the two sides stay symmetric.
  assert.match(peoplePanel, /const exact = switchesToExactMatch\(field, values\.length\);/);
  assert.match(peoplePanel, /exact \? "equals" : "contains"/);
  assert.match(peoplePanel, /exact \? "not_equals" : "not_contains"/);

  // Company DB bulk domain box. __website is a list of exact domains and has no
  // field variable in scope, so it keeps the size-only rule.
  assert.match(companyPanel, /merged\.length > exactMatchThreshold \? "equals" : "contains"/);
  // The CSV/xlsx import path does have a field, and must respect the exemption.
  assert.match(companyPanel, /switchesToExactMatch\(field, merged\.length\) \? "equals" : "contains"/);

  // The operator must reach the filter object, not just be computed and dropped.
  assert.doesNotMatch(companyPanel, /field, operator: "contains", values: merged/);
});

test("the equals branch for websites uses the indexed normalized_domain column", async () => {
  const migration = await readFile(
    new URL("../supabase/migrations/20260901000000_bulk_filters_match_exactly.sql", import.meta.url),
    "utf8",
  );

  assert.match(migration, /create or replace function public\.company_prefilter_sql/i);
  // lower(c.domain) has no index; normalized_domain does, and the two are equal on
  // every row (verified against production before the migration was written).
  assert.match(migration, /c\.normalized_domain = any \(%L::text\[\]\)/);
  assert.match(migration, /operator_key = 'equals' and field_key = '__website'/);

  // The generic equals branch must survive for every other field.
  assert.match(migration, /lower\(%s\) = any \(%L::text\[\]\)/);
  // And the bounded OR path stays for small typed lists, which the trigram index
  // can still serve.
  assert.match(migration, /bulk_or_threshold constant integer := 40/);
});
