import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

import { companyExportFields, icpValidationExportFields, buildCompanyExportColumns } from "../lib/company-export.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// The ICP validation file is a fixed five columns. It is a button, not a
// picker, so nothing in the UI stops the set drifting - only this.
test("the ICP validation export writes exactly the five review columns", () => {
  assert.deepEqual([...icpValidationExportFields].sort(), [
    "__company_keywords",
    "__company_name",
    "__industry",
    "__short_description",
    "__website",
  ]);

  // Every id resolves to a real column. An unknown id is not an error anywhere
  // in the export path - buildCompanyExportColumns simply filters it out - so a
  // typo would silently ship a file with a missing column.
  const known = new Set(companyExportFields.map((field) => field.id));
  for (const id of icpValidationExportFields) {
    assert.ok(known.has(id), `${id} is not a company export field`);
  }

  // The headers, in the order the CSV actually writes them: companyExportFields
  // order, not the order the array above happens to list.
  assert.deepEqual(buildCompanyExportColumns([], icpValidationExportFields).map((column) => column.header), [
    "Company Name",
    "Website",
    "Industry",
    "Keywords",
    "Short Description",
  ]);
});

// Both direct and background company exports carry the actual origin client.
// The server, not the browser, binds that identity to the internal company
// predicate before authorization and execution.
test("a client-scoped company export is bound by the server in both paths", async () => {
  const runner = await read("../lib/export-runner.ts");
  assert.match(runner, /clientScope: options\.clientId \?\? ""/);
  assert.match(runner, /clientId: options\.clientId \?\? ""/);
  assert.doesNotMatch(runner, /function withClientFilter/);

  const route = await read("../app/api/companies/route.ts");
  assert.match(route, /filters = withClientCompanyScope\(filters, clientId\)/);
});
