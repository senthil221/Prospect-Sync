import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { CLASSIFIER_VERSION, classificationCacheKey, classifyQuery } from "../lib/query-classifier.ts";

// Release 2, item 2: the rule-based classifier from section 6.1. Every rule
// below is one of the six the plan names, and the thresholds come from
// measurements recorded in 20260902000080 and 20260902000030.

const filter = (field, operator, values = [], extra = {}) => ({ field, operator, values, ...extra });
const many = (count, prefix = "term") => Array.from({ length: count }, (_, index) => `${prefix}${index}`);

test("rule 2: a pasted column of substring terms goes to background", () => {
  const under = classifyQuery([filter("__title", "contains", many(100))]);
  assert.notEqual(under.route, "background", "100 terms is the limit, not past it");

  const over = classifyQuery([filter("__title", "contains", many(101))]);
  assert.equal(over.route, "background");
  assert.equal(over.field, "__title");
  assert.match(over.reason, /101 substring terms/);
});

test("rule 3: a filter set that only excludes has nothing to narrow with", () => {
  const negativeOnly = classifyQuery([
    filter("__title", "not_contains", ["intern"]),
    filter("__company", "not_equals", ["acme"]),
  ]);
  assert.equal(negativeOnly.route, "background");
  assert.match(negativeOnly.reason, /excludes rather than selects/);

  // One positive alongside changes the answer: there is now something to
  // narrow with first.
  const withPositive = classifyQuery([
    filter("__title", "not_contains", ["intern"]),
    filter("__country", "equals", ["India"]),
  ]);
  assert.notEqual(withPositive.route, "background");
});

test("rule 5: Boolean stays interactive alone, and goes background in bad company", () => {
  const alone = classifyQuery([filter("__title", "boolean", ["ceo & founder"])]);
  assert.equal(alone.route, "interactive_capped");
  assert.match(alone.reason, /scans and stops early/);

  // Combined with something that also cannot use an index, the table is read
  // more than once.
  const combined = classifyQuery([
    filter("__title", "boolean", ["ceo & founder"]),
    filter("__esp", "contains", ["google"]),
  ]);
  assert.equal(combined.route, "background");
});

test("rule 4: a broad unindexed filter stays interactive, capped", () => {
  // Measured at 22% and 32% of rows: a sequential scan with early stop is the
  // correct plan, not a reason to go background.
  for (const field of ["__company_state", "__esp"]) {
    const result = classifyQuery([filter(field, "contains", ["something"])]);
    assert.equal(result.route, "interactive_capped", `${field} should stay interactive`);
  }
});

test("an indexed substring is fully interactive, a two-character one is not", () => {
  // These eight columns were indexed in 20260902000080 with before/after plans.
  for (const field of ["__name", "__first_name", "__last_name", "__linkedin", "__company_domain", "__personal_email", "__tags", "__company_country"]) {
    const result = classifyQuery([filter(field, "contains", ["rajesh"])]);
    assert.equal(result.route, "interactive", `${field} is index-served`);
  }

  // pg_trgm extracts no trigram from two characters, so the index cannot serve
  // it - measured at 1,107 ms against a ~530 ms scan. Bounded, so still
  // interactive, but capped and honest about why.
  const short = classifyQuery([filter("__name", "contains", ["vp"])]);
  assert.equal(short.route, "interactive_capped");
  assert.match(short.reason, /one or two character search/);
  assert.equal(short.field, "__name");
});

test("a set-backed equality is cheap however many values it holds", () => {
  const set = classifyQuery([filter("__company_domain", "equals", [], { setId: "11111111-1111-1111-1111-111111111111" })]);
  assert.equal(set.route, "interactive");
  // The same question inline, past the substring limit, is background - which
  // is the argument for sets carrying the big lists.
  const inline = classifyQuery([filter("__company_domain", "contains", many(500, "acme"))]);
  assert.equal(inline.route, "background");
});

test("custom fields are affordable in ones and twos, not in bulk", () => {
  const two = classifyQuery([filter("custom:industry", "contains", ["saas"]), filter("custom:tier", "contains", ["a"])]);
  assert.notEqual(two.route, "background");

  const three = classifyQuery([
    filter("custom:industry", "contains", ["saas"]),
    filter("custom:tier", "contains", ["a"]),
    filter("custom:region", "contains", ["emea"]),
  ]);
  assert.equal(three.route, "background");
  assert.match(three.reason, /raw JSON of every row/);
});

test("an empty query is the cheapest thing there is", () => {
  const result = classifyQuery([], "");
  assert.equal(result.route, "interactive");
  assert.match(result.reason, /reads the index directly/);
});

test("the classification is versioned, and the version is in the cache key", () => {
  // Section 6.1: a classification cached on content alone survives an index
  // build or an ANALYZE and then routes a now-indexed shape to background.
  assert.equal(typeof CLASSIFIER_VERSION, "number");
  assert.equal(classifyQuery([]).classifierVersion, CLASSIFIER_VERSION);
  assert.equal(classificationCacheKey("abc123"), `abc123:c${CLASSIFIER_VERSION}`);
  assert.notEqual(classificationCacheKey("abc123"), "abc123");
});

test("the classifier never touches the database", async () => {
  const source = await readFile(new URL("../lib/query-classifier.ts", import.meta.url), "utf8");
  // The prose explains the rule by quoting it, so the check has to be asked of
  // the code alone.
  const code = source.split("\n").filter((line) => !line.trimStart().startsWith("//")).join("\n");
  // The rule that makes this design worth having: no EXPLAIN, no query, no
  // round trip on the request path. It is also why classifyQuery is not async.
  assert.doesNotMatch(code, /EXPLAIN|createAdminClient|supabase|fetch\(|await /i);
  assert.doesNotMatch(code, /async /);
  assert.match(source, /never runs EXPLAIN on the request path/);
});
