import assert from "node:assert/strict";
import test from "node:test";
import { mapProspect, parseEmployeeCount } from "../db/normalize.ts";
import { buildCustomFieldDefinitions, customFieldValue } from "../lib/prospect-fields.ts";

test("imports Keywords separately from Job Title and parses company fields", () => {
  const headers = ["Job Title", "Keywords", "# Employees", "Company City", "Company Country", "Work Email"];
  const prospect = mapProspect(headers, ["VP Sales", "SaaS, Revenue; B2B | saas", "1,001-2,000", "Dublin", "Ireland", "person@example.com"]);
  assert.equal(prospect.title, "VP Sales");
  assert.deepEqual(prospect.keywords, ["SaaS", "Revenue", "B2B"]);
  assert.equal(prospect.companyEmployeeCountMin, 1001);
  assert.equal(prospect.companyEmployeeCountMax, 2000);
  assert.equal(prospect.companyCity, "Dublin");
  assert.equal(prospect.companyCountry, "Ireland");
});

test("parses exact, ranged, open-ended, and unknown employee counts", () => {
  assert.deepEqual(parseEmployeeCount("250"), { min: 250, max: 250 });
  assert.deepEqual(parseEmployeeCount("501 - 1,000"), { min: 501, max: 1000 });
  assert.deepEqual(parseEmployeeCount("10,001+"), { min: 10001, max: null });
  assert.deepEqual(parseEmployeeCount("Unknown"), { min: null, max: null });
});

test("normalizes duplicate imported headers without discarding their values", () => {
  const definitions = buildCustomFieldDefinitions(["Industry Type", "industry_type", "INDUSTRY-TYPE", "Job Title"]);
  assert.deepEqual(definitions, [{ id: "custom:industrytype", label: "Industry Type", sourceFields: ["Industry Type", "industry_type", "INDUSTRY-TYPE"] }]);
  assert.equal(customFieldValue({ "Industry Type": "SaaS", industry_type: "Technology" }, "industrytype"), "SaaS | Technology");
});
