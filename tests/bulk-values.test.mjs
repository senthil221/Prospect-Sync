import assert from "node:assert/strict";
import test from "node:test";
import { bulkFieldKind, describeBulkMerge, isValidBulkValue, mergeBulkValues, normalizeBulkValue, partitionBlocklistValues, splitPastedValues } from "../lib/bulk-values.ts";
import { FilterLimitError, maxFilterValues, maxFilters, parseFilters } from "../lib/prospect-filters.ts";

test("splits the separators a pasted spreadsheet column actually uses", () => {
  assert.deepEqual(splitPastedValues("acme.com\nstripe.com"), ["acme.com", "stripe.com"]);
  assert.deepEqual(splitPastedValues("acme.com, stripe.com; contoso.com"), ["acme.com", "stripe.com", "contoso.com"]);
  assert.deepEqual(splitPastedValues("acme.com\tstripe.com"), ["acme.com", "stripe.com"]);
  assert.deepEqual(splitPastedValues("acme.com\r\n\r\nstripe.com"), ["acme.com", "stripe.com"]);
  // Quotes from a copied CSV cell and list bullets must not become part of the value.
  assert.deepEqual(splitPastedValues('"acme.com"\n• stripe.com'), ["acme.com", "stripe.com"]);
  assert.deepEqual(splitPastedValues("   \n  \n"), []);
});

test("normalizes pasted values into the form the database stores", () => {
  assert.equal(normalizeBulkValue("https://www.acme.com/careers?ref=x", "domain"), "acme.com");
  assert.equal(normalizeBulkValue("WWW.Stripe.COM", "domain"), "stripe.com");
  assert.equal(normalizeBulkValue("  Ada@Example.COM ", "email"), "ada@example.com");
  assert.equal(normalizeBulkValue("https://LinkedIn.com/in/Ada/?x=1", "linkedin"), "https://linkedin.com/in/ada");
  assert.equal(normalizeBulkValue("  VP Sales  ", "text"), "VP Sales");
});

test("rejects the junk that rides along with a pasted column", () => {
  // A header row pasted with the data would otherwise become a filter value that
  // matches nothing and silently shrinks the result set.
  assert.equal(isValidBulkValue("website", "domain"), false);
  assert.equal(isValidBulkValue("acme.com", "domain"), true);
  assert.equal(isValidBulkValue("acme", "email"), false);
  assert.equal(isValidBulkValue("ada@example.com", "email"), true);
  assert.equal(isValidBulkValue("anything at all", "text"), true);
});

test("merging reports added, duplicate, and skipped counts instead of dropping rows", () => {
  const result = mergeBulkValues(["acme.com"], "https://www.acme.com\nstripe.com\nWebsite\ncontoso.co.uk", "domain");
  assert.deepEqual(result.values, ["acme.com", "stripe.com", "contoso.co.uk"]);
  assert.equal(result.added, 2);
  assert.equal(result.duplicates, 1, "the pasted URL normalizes onto the existing acme.com");
  assert.deepEqual(result.invalid, ["Website"]);
  assert.match(describeBulkMerge(result, "domain"), /2 domains added · 1 already listed · 1 skipped \(Website\)/);
});

test("a large domain blocklist keeps every processing value while bounding only diagnostics", () => {
  const domains = Array.from({ length: 1875 }, (_, index) => `https://www.company-${index}.com/careers`);
  const result = partitionBlocklistValues([...domains, "NO WEBSITE", "NO DOMAIN", "person@example.com"].join("\n"));
  assert.equal(result.submitted, 1878);
  assert.equal(result.domains.length, 1875, "the processing payload must not inherit the ten-item diagnostic cap");
  assert.equal(result.emails.length, 1);
  assert.equal(result.invalidCount, 2);
  assert.deepEqual(result.invalid, ["NO WEBSITE", "NO DOMAIN"]);
  assert.equal(result.domains.at(-1), "company-1874.com");
});

test("field ids map to the normalization their stored column needs", () => {
  assert.equal(bulkFieldKind("__website"), "domain");
  assert.equal(bulkFieldKind("__company_domain"), "domain");
  assert.equal(bulkFieldKind("__work_email"), "email");
  assert.equal(bulkFieldKind("__linkedin"), "linkedin");
  assert.equal(bulkFieldKind("__title"), "text");
  assert.equal(bulkFieldKind(undefined), "text");
});

test("a pasted column of hundreds of values survives filter parsing", () => {
  // The old cap was 50: pasting 500 domains silently discarded 450 of them and
  // returned a confidently wrong result set.
  const values = Array.from({ length: 500 }, (_, index) => `company-${index}.com`);
  const [filter] = parseFilters(JSON.stringify([{ field: "__website", operator: "contains", values }]));
  assert.equal(filter.values.length, 500);
  assert.equal(filter.values.at(-1), "company-499.com");
});

test("an over-cap payload is refused, never trimmed to fit", () => {
  // The ceiling moved from 1,000 to 5,000 once a pasted list became an indexed
  // equality test and the company scope stopped calling the per-row predicate.
  // It is still a ceiling -- but crossing it is now an error, not a quiet trim
  // that returns a confidently wrong answer for the values that survived.
  const values = Array.from({ length: 20000 }, (_, index) => `v${index}`);
  assert.throws(
    () => parseFilters(JSON.stringify([{ field: "__title", operator: "contains", values }])),
    (error) => error instanceof FilterLimitError
      && error.kind === "values"
      && error.received === 20000
      && error.allowed === maxFilterValues
      && error.field === "__title",
  );

  // Exactly at the cap still parses: the boundary is inclusive.
  const atCap = Array.from({ length: maxFilterValues }, (_, index) => `v${index}`);
  const [filter] = parseFilters(JSON.stringify([{ field: "__title", operator: "contains", values: atCap }]));
  assert.equal(filter.values.length, maxFilterValues);

  const many = Array.from({ length: maxFilters + 1 }, () => ({ field: "__title", operator: "contains", values: ["x"] }));
  assert.throws(
    () => parseFilters(JSON.stringify(many)),
    (error) => error instanceof FilterLimitError && error.kind === "filters" && error.allowed === maxFilters,
  );

  // The stated target workload is 50 simultaneously active filters.
  const fifty = Array.from({ length: 50 }, () => ({ field: "__title", operator: "contains", values: ["x"] }));
  assert.equal(parseFilters(JSON.stringify(fifty)).length, 50);
});

test("company keyword scopes are defaulted, whitelisted, and preserved", () => {
  const [defaults] = parseFilters(JSON.stringify([
    { field: "__company_keywords", operator: "contains", values: ["cold email"] },
  ]));
  assert.deepEqual(defaults.scopes, ["name", "keywords"]);

  const [scoped] = parseFilters(JSON.stringify([
    { field: "__company_keywords", operator: "contains", values: ["deliverability"], scopes: ["description", "keywords", "private_column", "description"] },
  ]));
  assert.deepEqual(scoped.scopes, ["description", "keywords"]);

  const [ordinary] = parseFilters(JSON.stringify([
    { field: "__website", operator: "contains", values: ["example.com"], scopes: ["description"] },
  ]));
  assert.equal(ordinary.scopes, undefined);
});
