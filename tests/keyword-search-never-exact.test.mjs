import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { describeMatchMode, exactMatchThreshold, matchesExactly, switchesToExactMatch } from "../lib/bulk-values.ts";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");

// Reported as "I enabled Company description and only 3 prospects got added".
//
// Pasting 51 keywords crossed exactMatchThreshold, which switched the operator
// from contains to equals. Under equals the description scope tests
// `lower(short_description) = any(values)` -- a whole paragraph equalling the
// string "IT services" -- true for 13 companies out of 419,214. Measured on that
// real 51-keyword list: exact mode found 27,480 companies / 54,423 prospects,
// contains finds 38,448 / 73,094. A third of the answer, silently missing.
test("a keyword search never switches to exact matching, at any list size", () => {
  for (const count of [1, 25, 26, 51, 500, 5000]) {
    assert.equal(switchesToExactMatch("__company_keywords", count), false,
      `${count} keywords must still be a substring search`);
  }
});

// The switch is right for pasted identifiers: acme.com is a substring of
// notacme.com.au, and equality is the indexable test.
test("pasted identifier lists still switch, so that protection is intact", () => {
  for (const field of ["__website", "__company", "__company_domain", "__email"]) {
    assert.equal(switchesToExactMatch(field, exactMatchThreshold), false, `${field} below the threshold is contains`);
    assert.equal(switchesToExactMatch(field, exactMatchThreshold + 1), true, `${field} above the threshold is exact`);
  }
  // The size-only helper is unchanged; only the field-aware wrapper is new.
  assert.equal(matchesExactly(exactMatchThreshold), false);
  assert.equal(matchesExactly(exactMatchThreshold + 1), true);
});

// The note under the box is what tells a user why a count moved. It must not
// announce a switch that no longer happens.
test("the match-mode note tells the truth per field", () => {
  assert.match(describeMatchMode(51, "value", "__website"), /exactly/);
  assert.match(describeMatchMode(51, "value", "__company_keywords"), /contains/);
  assert.match(describeMatchMode(5, "value", "__website"), /contains/);
  assert.equal(describeMatchMode(0, "value", "__website"), "");
});

// Both panels choose the operator; both must ask the field-aware helper, or the
// exemption applies in one place and not the other.
test("every operator switch is field-aware", async () => {
  const apollo = await read("../app/ApolloFilterPanel.tsx");
  const company = await read("../app/CompanyFilterPanel.tsx");

  assert.match(apollo, /const exact = switchesToExactMatch\(field, values\.length\);/);
  assert.doesNotMatch(apollo, /values\.length > exactMatchThreshold/,
    "the raw size comparison bypasses the keyword-search exemption");
  assert.match(company, /switchesToExactMatch\(field, merged\.length\) \? "equals" : "contains"/);
  // __website keeps the size-only rule deliberately: it is a list of exact
  // domains and has no field variable in scope there.
  const websiteSite = company.slice(company.indexOf("export function addDomainsToWebsiteFilter"));
  assert.match(websiteSite, /merged\.length > exactMatchThreshold \? "equals" : "contains"/);
});

// The exemption is a semantic claim about the field, so it belongs with the
// threshold rather than being re-decided at each call site.
test("the exempt fields are declared once, next to the threshold", async () => {
  const source = await read("../lib/bulk-values.ts");

  assert.match(source, /const keywordSearchFields = new Set\(\["__company_keywords"\]\);/);
  assert.match(source, /return !keywordSearchFields\.has\(field\) && matchesExactly\(valueCount\);/);
});
